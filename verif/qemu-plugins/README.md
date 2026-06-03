# `verif/qemu-plugins` — Producer B: QEMU TCG cycle-trace plugin

`p5trace.c` builds into `build/p5trace.so`, a QEMU TCG plugin (QEMU 8.2.2 API,
`QEMU_PLUGIN_VERSION 1`) that rides functional execution of
`qemu-i386 -cpu pentium` and emits a **cycle-mode `.vtrace`** — the Producer B
side of the Ventium differential-testing stack (see
[`../../PLAN.md`](../../PLAN.md) §4.1 and
[`../../docs/trace-format.md`](../../docs/trace-format.md) §2.3).

For every **retired** instruction it appends one JSON-Lines record:

```json
{"n":0,"pc":"0x08049092","cyc":9,"pipe":"U","paired":false,"stall":8,"bytes":"31ed"}
```

The first line is the header object:

```json
{"vtrace":1,"producer":"qemu-plugin","mode":"cycle","x87":false,"note":"p5trace: ..."}
```

## The cycle model

The model is the **same** in-order, dual-pipe (U/V) Pentium (P5/P54C, non-MMX)
cycle estimate as
[`ventium-refs/07-p5-emulation-harness/plugin/p5model.c`](../../ventium-refs/07-p5-emulation-harness/plugin/p5model.c):

- **U/V pairing** per Intel AP-500 / Agner Fog pairing classes;
- **RAW result latency** per the Agner P5 latency table (dependency-chain stalls);
- **AGI** — 1-cycle stall when an address base/index reg was written in the
  immediately preceding cycle (AP-500);
- **branch prediction** — 256-entry, 4-way BTB with 2-bit saturating counters;
  mispredict = 3 (U-pipe) / 4 (V-pipe) cycles, 3 for taken uncond/`call`;
- **L1 caches** — 8 KB 2-way I + 8 KB 2-way D, 32-byte lines (P54C);
- **misaligned data** — +3 cycles (AP-500).

The classification, cache, BTB and timing-core code are lifted from `p5model.c`
and condensed (the instruction-mix histogram, which only fed `p5model`'s
aggregate report, is dropped). It is verified to produce **identical** cycle/
pairing totals to `p5model` on the same binary — see the self-test below.

### Difference from `p5model`

`p5model` prints one aggregate JSON blob at exit. **`p5trace` instead appends a
per-retired-instruction cycle record** as execution proceeds. Records are
buffered in memory and flushed in the `qemu_plugin_register_atexit_cb` callback
(faster than per-record I/O, and avoids interleaving with QEMU's own stderr).

This is a cycle **estimate** for L1-resident, single-threaded user-mode code —
not cycle-exact silicon. See the harness README "What it does NOT model" and
[`../../PLAN.md`](../../PLAN.md) §8.

## Record fields (`docs/trace-format.md` §2.1 + §2.3)

| key | meaning |
|---|---|
| `n` | retire sequence number, 0-based, strictly increasing |
| `pc` | fetch vaddr of the retired instruction, `"0x%08x"` lowercase |
| `cyc` | **cumulative** core-clock count at this instruction's retire |
| `pipe` | `"U"` (started a fresh issue group / held the U pipe), `"V"` (paired into the open V slot), or `"-"` (reserved; unused here) |
| `paired` | `true` iff the instruction issued paired (always with `pipe:"V"`) |
| `stall` | *(optional)* stall cycles attributed to this retire (AGI / I-/D-cache miss / branch-mispredict bubble / prefix-decode) |
| `bytes` | *(optional)* raw instruction bytes, lowercase hex, no `0x` |

`cyc` is cumulative so the comparator derives per-instruction cost as
`cyc[n] - cyc[n-1]` and the total without summing.

## Building

The top-level `Makefile` drives it (it passes abspaths):

```sh
make plugin          # from the repo root → build/p5trace.so
```

Or standalone from this directory:

```sh
make                 # uses the in-tree submodule paths by default
make clean
```

Override the two prerequisites when the harness lives elsewhere:

```sh
make QEMU_SRC=/path/to/qemu CAPSTONE=/path/to/capstone
```

`QEMU_SRC` must contain `include/qemu/qemu-plugin.h`; `CAPSTONE` must contain
`include/` and `libcapstone.a`. Build mirrors
`ventium-refs/.../scripts/30-build-plugin.sh` (`-fPIC`, `pkg-config glib-2.0`,
`-I$(QEMU_SRC)/include/qemu -I$(CAPSTONE)/include`, link the static
`libcapstone.a`).

## Running

```sh
QEMU=ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386
$QEMU -cpu pentium -plugin build/p5trace.so,out=/tmp/cyc.vtrace <static-elf>
```

### Plugin arguments (comma-separated after the `.so` path)

| arg | default | meaning |
|---|---|---|
| `out=<path>` | stderr | output `.vtrace` file |
| `imiss=<n>` | `8` | I-cache miss penalty (cycles) — a modelling assumption (P5 docs don't pin it) |
| `dmiss=<n>` | `8` | D-cache (read) miss penalty (cycles) |
| `cache=<0\|1>` | `1` | model the L1 I/D caches; `0` = ideal (no miss penalties) |
| `bytes=<0\|1>` | `1` | include the optional `bytes` field per record |

## Self-test (what was verified)

1. Built `build/p5trace.so` via `make plugin` (clean compile, no warnings).
2. Built a tiny static i586 ELF with the harness `tools/p5cc` (an integer loop
   with pairable ALU, a shift, a store and a load — exercises U/V pairing, AGI,
   the BTB and the D-cache). Falls back to `gcc -m32 -march=pentium` if the
   P5 musl toolchain isn't present.
3. Ran `qemu-i386 -cpu pentium -plugin build/p5trace.so,out=/tmp/cyc.vtrace`.
4. Parsed `/tmp/cyc.vtrace` with `verif/diff/tracefmt.read_trace` and asserted:
   valid header (`vtrace:1`, `producer:"qemu-plugin"`, `mode:"cycle"`,
   `x87:false`); `n` strictly increasing from 0; `cyc` non-decreasing; `pc` is
   `0x`+8 hex; `pipe ∈ {U,V,-}`; `paired` ⇒ `pipe=="V"`; `stall`/`bytes` present
   and well-formed.
5. Cross-checked the aggregate against `p5model.so` on the same binary:
   **identical** instruction count, cycle estimate, pairing count and CPI.
