# Ventium test corpus (`verif/tests/`)

The deterministic test programs the verification stack runs, plus the loader
helper that turns a test ELF into the flat memory image the Verilator testbench
preloads. See [`../../PLAN.md`](../../PLAN.md) §4 (verification) and the **M0**
gate, [`../../docs/trace-format.md`](../../docs/trace-format.md) §4 (M0
expectation), and [`../../docs/rtl-interface.md`](../../docs/rtl-interface.md) §4
(image loading).

## Contents

| path | what |
|---|---|
| `smoke/smoke.s`        | M0 smoke program: short, deterministic, pure original-Pentium asm |
| `smoke/smoke.elf`      | built freestanding 32-bit i386 ELF *(build artifact)* |
| `smoke/smoke.flat`     | flat code image for the testbench *(build artifact)* |
| `smoke/manifest.json`  | metadata the TB + trace generators consume |
| `elf2flat.py`          | ELF → flat-blob loader helper |
| `Makefile`             | builds + verifies the corpus |

`smoke.elf` and `smoke.flat` are generated; only `smoke.s`, `manifest.json`,
`elf2flat.py`, `Makefile` and this README are source.

## Build / verify

From the repo root (the integration entry point):

```sh
make -C verif/tests          # build smoke.elf, ISA-verify, flatten -> smoke.flat,
                             # and validate manifest.json against the built ELF
make -C verif/tests run      # run smoke.elf under the harness QEMU (must exit 0)
make -C verif/tests clean    # remove build artifacts
```

Other targets: `verify` (re-run the static ISA check), `check-manifest`
(re-validate the manifest without rebuilding the image).

Requires only the host toolchain: `gcc -m32` (GNU as/ld), `python3` (+ `capstone`
for `isa_verify.py`), `make`, and the harness QEMU at
`ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386`.

## The smoke program (`smoke/smoke.s`)

A ~22-retired-instruction freestanding `_start` that exercises the clock / reset
/ retire / trace path end-to-end at M0 without needing real x86 in the RTL stub.
It uses **original-Pentium-only** integer instructions and deliberately avoids
every instruction that leaves EFLAGS architecturally undefined, so the
differential comparator can compare EFLAGS for *every* record with no per-record
masking:

- used: `mov`, `add`, `sub`, `and`, `or`, `xor`, `inc`, `dec`, `lea`,
  `push`/`pop`, `cmp`, `test`, `nop`, `jmp`/`jcc`
- **not** used: `mul`/`imul`/`div`/`idiv`/`bsf`/`bsr`/`daa`/`das` and CL-count
  shifts (these define undefined flags — see `tracefmt.EFLAGS_UNDEFINED`), and
  no MMX/SSE/CMOV (post-P5).

It includes two never-taken sentinel `mov`s (immediately after a taken `je` /
`jnz`) to exercise correct branch behaviour; `isa_verify` decodes all 24 static
instructions, but only 22 retire. The program ends with the standard Linux i386
`_exit(0)`:

```asm
mov $1, %eax        # __NR_exit
xor %ebx, %ebx      # status 0
int $0x80
```

so it terminates cleanly under QEMU's linux-user mode (exit code 0). The
`int $0x80` is also a natural end-of-trace marker for the testbench.

## Manifest (`smoke/manifest.json`)

```json
{
  "name": "smoke",
  "src": "smoke/smoke.s",
  "elf": "smoke/smoke.elf",
  "image": "smoke/smoke.flat",
  "load_addr": "0x08048000",
  "entry": "0x08048000",
  "max_insn": 22
}
```

- `load_addr` — base virtual address the flat `image` is positioned at: byte
  `image[vaddr - load_addr]` is the byte mapped at `vaddr`. Reset EIP/PC init =
  `entry` (`docs/rtl-interface.md` §4).
- `entry` — the ELF entry point (`readelf -h`); here it equals `load_addr`
  because `.text` is pinned at the load address, so `image[0]` is the first
  instruction. Recorded in canonical 32-bit hex matching `tracefmt.h32`.
- `max_insn` — number of instructions that actually **retire** (22). The
  trace producers / testbench can use it as the expected trace length / a run
  cap.

Paths in the manifest are **relative to `verif/tests/`** (the manifest's grand-
parent-agnostic anchor), so consumers should resolve `image`/`elf`/`src` against
that directory.

## `elf2flat.py` — ELF → flat blob

Pure-stdlib helper that parses the ELF header + program headers and concatenates
the `PT_LOAD` bytes into a flat blob, zero-filling gaps and `.bss` tails.

```sh
elf2flat.py <elf> --out <blob> [--base 0xADDR] [--check-manifest <json>]
```

- `--base` sets the blob origin (the manifest `load_addr`). It defaults to the
  lowest loadable vaddr. The M0 toolchain emits a tiny read-only segment for the
  ELF/program headers one page *below* the code (e.g. `0x08047000` vs the
  `0x08048000` text); passing `--base 0x08048000` clips that sub-base segment
  off so the blob is exactly the code image starting at the entry. (The
  bare-metal TB only loads/executes from `load_addr` upward.)
- `--check-manifest` validates a `manifest.json` against the freshly-computed
  ELF facts (entry / load base / required keys / image presence) and exits
  non-zero on any mismatch — the Makefile uses this so the image and its
  metadata can never drift. It prints `entry=`, `load_addr=`, `image=` lines for
  scripting.

### Why this load layout (integration note)

The smoke ELF is built `gcc -m32 -nostdlib -static -Wl,--build-id=none
-Wl,-Ttext=0x08048000`. That yields two `PT_LOAD` segments — a read-only headers
page at `0x08047000` and the `R E` code at `0x08048000` — and *runs cleanly under
QEMU's linux-user loader* (which requires `p_offset ≡ p_vaddr (mod page)`). An
omagic (`-n`) single-segment layout would put load_addr == entry == the code
address too, but QEMU rejects its non-page-congruent mapping, so we keep the
two-segment layout and let `elf2flat --base 0x08048000` produce the clean
code-only image. The TB never needs the headers segment.
