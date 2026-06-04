# Ventium M2S.0 — system-mode differential oracle + bare-metal harness

This directory is the **bounded de-risk step** before the M2S RTL stages
(protected-mode segmentation, paging, interrupts, TSS, SMM, debug). It stands up
the *system-mode functional oracle* and a bare-metal test harness, and
demonstrates a system-state golden trace round-tripping. **There is NO RTL here**
— the RTL work begins at M2S.1. The user-mode roadmap (M0–M6) and `make verify`
are untouched.

See [`../../docs/m2s-system-spec.md`](../../docs/m2s-system-spec.md) for the
scoped M2S plan and [`../../docs/trace-format.md`](../../docs/trace-format.md) §2.4
for the system trace fields.

## What's here

| path | what |
|---|---|
| `build-qemu-system.sh` | idempotent build of `qemu-system-i386` (i386-softmmu) for the oracle |
| `run-sys-golden.sh` | end-to-end: build qemu-system + image, run it, generate + validate the golden |
| `tests/pmode/` | bare-metal real→protected→paging demonstrator (image + build flow + manifest) |

The trace plumbing lives in the shared tools (extended, not forked):
- `../qemu-trace/gen_trace.py --system` — Producer A in system mode.
- `../diff/tracefmt.py` — the `sys:true` header flag + `cr0/cr2/cr3/cr4` fields
  and the reserved segment-hidden fields.

## 1. Build the system-mode QEMU

```sh
bash verif/sys/build-qemu-system.sh
```

Configures + builds `qemu-system-i386` **out-of-tree** in
`ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/` with
`--target-list=i386-softmmu --enable-plugins --python=/usr/bin/python3
--disable-tools --disable-docs --disable-werror`. It reuses the same QEMU 8.2.2
source tree the user-mode build cloned, in a **separate** `build-sys/` directory,
so the user-mode `qemu-i386` (which `make verify` depends on) is never disturbed.
Idempotent: skips the build if the binary already exists.

## 2. The system-mode oracle: `gen_trace.py --system`

`gen_trace.py` gained a system-mode launch path. It starts

```
qemu-system-i386 -display none -S -gdb tcp::PORT -machine pc -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios <image>
```

connects the existing RSP client (the **same** `RSPClient` + `discover_layout` +
`anchor_tail` the user-mode path uses), single-steps from the real-mode reset
vector (`CS:EIP = F000:FFF0`, `cr0.PE=0`), and emits one **system** func record
per instruction carrying — in addition to the user-mode fields (pc, eflags, the 8
GPRs, the 6 selectors) — the control registers **`cr0/cr2/cr3/cr4`** plus the
available reserved segment-hidden bases, with header `sys:true`. It stops when the
guest hits the `isa-debug-exit` (qemu exits → gdb socket closes, handled as a
clean exit) or `--max-insn`/`--stop-at`.

```sh
python3 verif/qemu-trace/gen_trace.py \
    --qemu .../build-sys/qemu-system-i386 \
    --system --image <image.bin> --image-mode bios \
    --out build/sys/<name>.sys.vtrace --max-insn 4000
```

### The `anchor_tail` extension (why CRx lands correctly)

QEMU's i386-softmmu `g`-packet is 344 bytes while the target-description layout
totals 356 — it omits 3 advertised middle registers (12 bytes). Empirically
(verified against QMP `info registers`) `cr0/cr2/cr3/cr4` AND the FP tail all
shift by that same −12 (cr0 naive @88 → real @76; st0 @112 → @100). The existing
tail-anchor was extended to anchor the shift to the **earlier of {cr0, st0}** so
the CRx block is placed correctly. For the user-mode layout cr0 reads 0 and is
never emitted, and st0 is still ≥ cr0's offset, so the FP-tail placement is
**byte-for-byte identical** to before — a pure superset.

## 3. The bare-metal test: `tests/pmode/`

A freestanding 64 KiB BIOS image (`pmode.bin`) that, from the reset vector:

1. real mode — loads a flat GDT (null / 32-bit code / 32-bit data);
2. sets `CR0.PE` and far-jumps into the 32-bit code segment (selector `0x08`);
3. runs a handful of protected-mode instructions;
4. builds a 4 MiB identity-mapped **PSE** page directory, sets `CR4.PSE`, loads
   `CR3`, sets `CR0.PG`;
5. runs a few more paged instructions and exits via `out 0xf4, 0x42`
   (isa-debug-exit → qemu process status `(0x42<<1)|1 = 133`).

Build flow (toolchain: a 32-bit-capable `gcc -m32` + GNU `ld`/`objcopy`):

```sh
make -C verif/sys/tests/pmode      # -> pmode.bin (exactly 64 KiB)
```

`pmode.S` is GNU-as (no nasm needed); `pmode.ld` places the 16-bit reset stub at
image offset `0xFFF0` (linear `F:FFF0`) and the body in segment `0xF000`. See
`tests/pmode/manifest.json` for the load/exit metadata and the transitions the
golden shows.

## 4. Demonstrate the golden

```sh
bash verif/sys/run-sys-golden.sh           # default test = pmode
```

This builds everything (idempotently), confirms the image runs to the
isa-debug-exit, generates `build/sys/pmode.sys.vtrace`, and validates it is
well-formed (parses with `tracefmt`, all func+sys fields present at their declared
widths, `n` strictly 0..N-1) **and** that it captures the mode transitions:

```
CR0.PE 0->1 : n=20   pc=0x00000063 cr0->0x60000011   (real -> protected)
CS far-jump : n=21   pc=0x00000066 cs 0xf000->0x0008
CR3 load    : n=1072 pc=0x000f00c3 cr3->0x00010000   (page-directory base)
CR0.PG 0->1 : n=1075 pc=0x000f00ce cr0->0xe0000011   (paging enabled)
```

A reference copy of the validated golden is checked in at
`tests/pmode/pmode.sys.vtrace.golden`.

## Scope boundary

M2S.0 is **oracle + harness only**. The comparator (`compare.py`) is unchanged —
it does not yet diff the sys fields, because there is no RTL system producer to
diff against; that arrives at M2S.1 (segmentation), M2S.2 (paging), etc. The
trace *format* and *oracle* are now ready for those stages.
