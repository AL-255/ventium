# Producer A — QEMU gdbstub golden architectural-state trace

`gen_trace.py` is **Producer A** of the Ventium differential-testing stack
(see [`../../PLAN.md`](../../PLAN.md) §4.1 and
[`../../docs/trace-format.md`](../../docs/trace-format.md)). It is the
**functional oracle** for the whole project: it emits a functional-mode
`.vtrace` of the full per-instruction architectural state by single-stepping a
32-bit i386 ELF under QEMU and reading the register file over the GDB Remote
Serial Protocol (RSP).

## Why the gdbstub (and not a TCG plugin)?

QEMU 8.2.2's *plugin* API (`QEMU_PLUGIN_VERSION 1`) **cannot read register
values** — `qemu_plugin_read_register` only arrived in QEMU 9.0. Plugins can see
PC, instruction bytes, and memory addresses (that is Producer B's job,
`../qemu-plugins/p5trace.c`), but the architectural register file is *only*
observable through the gdbstub that `qemu-i386 -g <port>` exposes. So we
single-step the guest over RSP and read all registers after each instruction.

The client speaks RSP **directly over a TCP socket** — there is **no dependency
on a host `gdb` binary** and **no third-party Python packages** (stdlib only).

## Usage

```
gen_trace.py --qemu <path> --elf <file> --out <trace.vtrace>
             [--max-insn N] [--port P] [--x87] [--stop-at 0xADDR]
             [--no-bytes] [--verbose] [--args ...]
```

| flag | meaning |
|---|---|
| `--qemu` | path to the plugin/gdbstub-enabled `qemu-i386` |
| `--elf`  | the 32-bit i386 ELF to trace (statically linked recommended) |
| `--out`  | output `.vtrace` (JSON Lines, see trace-format.md) |
| `--max-insn N` | stop after N retired instructions (safety cap; default: run to exit) |
| `--port P` | gdbstub TCP port (default 1234) — pick a free one when parallelising |
| `--x87` | also emit x87 fields (`st0..st7`, `fctrl..fop`); header `x87:true` |
| `--stop-at 0xADDR` | stop when `EIP` reaches `ADDR` (before stepping it) |
| `--no-bytes` | do not read/emit the optional per-instruction `bytes` field |
| `--verbose` | dump every RSP packet to stderr (debugging) |
| `--args ...` | forwarded to the guest program (must be the **last** flag) |

### Example (the built-in self-test)

```sh
QEMU=../../ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386
printf '.global _start\n_start:\n mov $1,%%eax\n add $2,%%eax\n mov $1,%%eax\n xor %%ebx,%%ebx\n int $0x80\n' > /tmp/vt.s
gcc -m32 -nostdlib -static -o /tmp/vt.elf /tmp/vt.s
python3 gen_trace.py --qemu "$QEMU" --elf /tmp/vt.elf --out /tmp/vt.vtrace --max-insn 50
```

Produces records where `eax` becomes `1`, then `3`, then `1`, and the guest exit
(`int $0x80` / `W00`) is detected cleanly. Parse/validate the result with the
shared module:

```python
import sys; sys.path.insert(0, "../diff")
import tracefmt
t = tracefmt.read_trace("/tmp/vt.vtrace")          # raises on malformed input
assert [int(r["eax"], 16) for r in t.records] == [1, 3, 1, 1]
```

## Record / state convention

Per [`trace-format.md`](../../docs/trace-format.md) §2.1, **record `n` describes
the instruction *fetched* at `pc`, carrying the architectural state immediately
*after* that instruction commits** (post-state). The generation loop is:

```
read regs  -> pc = current eip      (fetch address of the insn about to run)
step       -> execute exactly one instruction
read regs  -> post-state; new eip is the NEXT insn's fetch address
emit {n, pc=old_eip, <post-state regs>}
```

Therefore `pc(record n+1) == next-eip(record n)` modulo control flow — the
redundant control-flow check the comparator (`../diff/compare.py`) may use.

Field names and hex formatting are produced **exclusively** through
`../diff/tracefmt.py` (`header()` / `func_record()` / `dumps()`), so they cannot
drift from the comparator's parser. Selectors are masked to 16 bits; GPRs/eflags
are 32-bit; x87 stack regs are 80-bit (20 hex digits).

## How the RSP register layout is derived

The `g` ("read general registers") packet is a flat, little-endian byte image of
the register file. Its layout is **not** assumed — it is discovered at runtime so
the slicing can never silently desync from the QEMU build in use:

1. Negotiate `qSupported` (and try `QStartNoAckMode` to drop per-packet acks).
2. Read the target description via `qXfer:features:read:target.xml:0,…`.
3. Follow each `<xi:include href="…"/>` (here: `i386-32bit.xml`, which also
   carries the i387/x87 regs) and parse every `<reg name="…" bitsize="…">` in
   **declaration order** — that order *is* the `g`-packet field order.
4. Build an ordered `(name, bits, byte_offset)` table and slice each field out of
   the `g` reply by offset, decoding little-endian.

### The layout QEMU 8.2.2 actually serves (verified live)

`qemu-i386`'s `i386-32bit.xml` describes **53 registers / 356 bytes**:

| offset (B) | regs | width |
|---|---|---|
| 0   | `eax ecx edx ebx esp ebp esi edi` | 32b each |
| 32  | `eip` | 32b |
| 36  | `eflags` | 32b |
| 40  | `cs ss ds es fs gs` | 32b each *(selector in low 16b)* |
| 64  | `ss_base ds_base es_base fs_base gs_base k_gs_base` | 32b each |
| 88  | `cr0 cr2 cr3 cr4 cr8 efer` | 32b each |
| 112 | `st0 … st7` | 80b each |
| 192 | `fctrl fstat ftag fiseg fioff foseg fooff fop` | 32b each |
| 224 | `xmm0 … xmm7` | 128b each |
| 352 | `mxcsr` | 32b |

Two important quirks this generator handles:

- **The `g` reply is truncated to ~344 bytes** (it stops partway through the
  `xmm` tail). All fields we emit — integer/system through `fop` at offset 224 —
  are fully present, so func and x87 modes are complete. A field whose bytes are
  absent is treated as `0`.
- **`cs..gs` occupy 32-bit slots** in the `g`-packet even though selectors are
  16-bit; we mask to 16 bits when mapping to the trace's `cs..gs` fields.

The slicing was cross-checked byte-for-byte against QEMU's authoritative
per-register `p<regnum>` reads (eax/eip/eflags/cs/esp all matched).

### Documented fallback layout

If `qXfer` is unavailable (older/odd stub), the code falls back to the **classic
i386 layout** in `FALLBACK_LAYOUT`:

```
eax ecx edx ebx esp ebp esi edi  (32b)
eip(32) eflags(32)
cs ss ds es fs gs                (32b each in the g-packet)
st0..st7                         (80b each)
fctrl fstat ftag fiseg fioff foseg fooff fop  (32b each)
```

The fallback omits QEMU's extra `ss_base..efer` block, so its x87 offsets would
not align with this particular build — but every **func-mode** field
(GPRs, `eip`, `eflags`, selectors), which is what the M1 comparator gates on, is
read identically by both layouts (verified live). Prefer the runtime-discovered
layout; the fallback exists only so a stub without `qXfer` still produces a
usable integer trace.

## Robustness notes (for the integration phase)

- **Process lifecycle:** the qemu child is always terminated/killed and reaped in
  a `finally` block, including on RSP errors or `KeyboardInterrupt`. Before
  closing, the client sends `k` (kill inferior) best-effort.
- **Connection:** TCP connect retries (~15 s) until the stub is listening.
- **Framing:** packets are `$<payload>#<cksum2hex>`, `cksum = sum(payload) & 0xff`.
  Good packets are acked with `+`; bad checksums request a resend with `-`;
  `QStartNoAckMode` is used when the stub accepts it. RSP `}` escaping (used in
  binary `qXfer` data) is decoded.
- **Timeouts:** all socket reads have a timeout (`RSPError` on expiry) so a hung
  qemu can never wedge the generator.
- **Unavailable register bytes:** if the stub reports a byte pair as `xx`, it is
  substituted with `0x00` (the register reads as `0`) rather than crashing.
- **Stop replies:** `T05`/`S05` = stopped (continue stepping); `W<code>` = exit;
  `X<sig>` = killed by signal — both stop tracing. `O…` console output mid-step
  is skipped and the real stop reply is re-read.
- **Exit detection** uses the `W`/`X` stop reply (not the post-step `g`), so the
  final `int $0x80`/`exit` instruction is *not* emitted with bogus post-state.
- **x87 caveat:** QEMU user-mode's gdbstub tracks the x87 stack lazily and may
  report stale/zeroed `st*`/`fstat`/`ftag` for short freestanding programs. The
  generator faithfully reports exactly what the stub exposes (its `g` slice
  equals QEMU's own `p<regnum>` reads); any x87-fidelity gap is QEMU's, not this
  tool's. This matters for M3 (x87 milestone) — validate the x87 oracle path on a
  real FP workload there.

## Integration

- Output is consumed by `../diff/compare.py` in **functional mode** (Producer A
  vs Producer C / the RTL). Header is
  `{"vtrace":1,"producer":"qemu-gdbstub","mode":"func","x87":<bool>,"note":…}`.
- Pure `python3` + stdlib; no build step. Import path to `tracefmt.py` is set up
  automatically (relative `../diff`).
- When running several traces concurrently, give each a distinct `--port`.
