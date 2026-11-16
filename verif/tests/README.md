# Ventium User-Mode Test Corpus (`verif/tests/`)

`verif/tests/` holds the deterministic freestanding 32-bit i386 user-mode assembly programs consumed by `make verify` (`m0-smoke`, `m1`..`m5`), `make x87b`, `make coverage`, and directed core/FPU regressions, along with the ELF flattener (`elf2flat.py`) and static non-MMX Pentium ISA checker (`isa_verify.py`).

## Corpus Families

Every program lives in its own subdirectory `<name>/` with assembly source (`.s`) and a `manifest.json` auto-discovered by the gate runners:

| Prefix / Directory | Milestone / Gate | Purpose |
| --- | --- | --- |
| `smoke/` | `m0-smoke` / `verify` | 22-retire pure-Pentium integer smoke sequence with zero undefined-EFLAGS ops, ending in Linux `int $0x80` (`_exit(0)`). |
| `t_*` | `m1`, `m2` / `verify` | User-mode integer ISA completeness: ALU, shifts/rotates, multiply/divide, BCD/ASCII adjust, bit test/scan (`BT*`/`BSF`/`BSR`), `SHLD`/`SHRD`, string ops (`MOVS`/`STOS`/`CMPS`/`SCAS` incl. `CX=0`), stack/frame (`ENTER`/`LEAVE`/`PUSH`/`POP`), branches, flags, and addressing modes. |
| `tx_*` | `m3` / `verify` | 80-bit x87 FPU functional corpus (`"x87": true`): `FLD`/`FST`/`FSTP`, integer/BCD loads & stores (`FILD`/`FIST`/`FBLD`/`FBSTP`), arithmetic (`FADD`/`FSUB`/`FMUL`/`FDIV`/`FSQRT`), rounding/scale (`FRNDINT`/`FSCALE`), exact remainders (`tx_fprem`, `tx_unifdiv`), comparisons (`FCOM*`/`FUCOM*`/`FTST`/`FXAM`), stack/environment ops (`FXCH`, `FLDENV`/`FNSTENV`, `FRSTOR`/`FNSAVE`), and `tx_transc` (`+VEN_TRANSCENDENTAL`). |
| `tx_deferred_halt/` | `make x87b` (`run_x87_boundary.sh`) | Deliberately excluded from `make verify`: verifies that `FSIN` (`D9 FE`) halts loudly (`S_HALT`) rather than silently mis-executing when `+VEN_TRANSCENDENTAL` is off. |
| `mb_*` | `m4`, `m5` / `verify` | Cycle-band microbenchmarks graded against `p5trace.so` (`verif/qemu-plugins/`) and emergent RTL `--cycle` traces: integer dependency/pairing/AGI/branch kernels (`mb_depadd`, `mb_indepadd`, `mb_agi`, `mb_brloop`, `mb_brrandom`, `mb_jmppair`, `mb_nearbr`, `mb_mul`, `mb_imul2`, `mb_rmimm`), L1 miss kernels (`mb_dmiss`, `mb_imiss`), and x87 latency/throughput/rename kernels (`mb_faddchain`, `mb_fpindep`, `mb_fxch`, `mb_fdivint`). |

> **Benchmark & Fixture Rules:**
> - **Never substitute microbenchmarks (`mb_*`) for physical Quake gameplay IPC.** Current verified physical gameplay baseline on `main` (`c0e3fe43`) is **`0.515778001` total U+V IPC** (`0.397847833` primary/U-only) across cycles `28,696,827,616–32,989,404,795`.
> - **Valid x87 Stack Fixtures (`mb_fxch`):** Throughput microbenchmarks must initialize valid x87 stack partners before entering timed loops (e.g., `mb_fxch` pushes `FLD1` before its 40-iteration body and pops `FSTP %st(0)` at teardown, keeping loop stack depth in `1..8` with zero stack-fault masks). Deliberate empty-stack `#IS` (`IE|SF`) fault behavior is tested separately in `make x87stk` (`verif/sys/tests/px87stk`) and `fp_shared/tb/tb_ven_fp_top.sv`.

## Building & Checking

```sh
make -C verif/tests          # build smoke.elf, run isa_verify.py, emit smoke.flat, check manifest.json
make -C verif/tests run      # execute smoke.elf under pinned ventium-refs/ qemu-i386
make -C verif/tests clean    # remove generated .elf/.flat build products
```

Full-corpus builds and static P5 ISA checks (`isa_verify.py` rejects post-P54C `CMOVcc`/`MMX`/`SSE`/`FCOMI` opcodes) are invoked automatically per test by `verif/verify.sh` (`make verify`).

Requires `gcc -m32` (GNU `as`/`ld`, `-nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000`), `python3` (+ `capstone`), and the pinned `ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386`.

## `manifest.json` Schema & `elf2flat.py`

```json
{
  "name": "smoke",
  "src": "smoke/smoke.s",
  "elf": "smoke/smoke.elf",
  "image": "smoke/smoke.flat",
  "load_addr": "0x08048000",
  "entry": "0x08048000",
  "max_insn": 22,
  "x87": false
}
```

- Paths (`src`, `elf`, `image`) resolve relative to `verif/tests/`.
- `elf2flat.py <elf> --out <flat> [--base 0x08048000] [--check-manifest <json>]` concatenates `PT_LOAD` segments from `--base` upward (clipping the linker's read-only `0x08047000` ELF header page while preserving page-congruent `p_offset ≡ p_vaddr` for QEMU `linux-user`) and verifies `entry`, `load_addr`, and `image` against `manifest.json`.
- Optional x87 oracle-gap masks (`x87_stkflt_arch`, `x87_stkflt_fstat_ranges`, `x87_stkflt_fpr_ranges`) are strictly bounded `[lo, hi]` record intervals checked by `make docs-status` (`verif/sys/run-docs-status-gate.sh`); open-ended (`null` upper-bound) masks and stale `PENDING`/`UNREACHED` status strings are rejected.
