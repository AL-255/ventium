# verif/trsc — x87 transcendental gates (#11)

Verification for the 8 x87 transcendental engines (`+VEN_TRANSCENDENTAL`). See
`docs/m11-transcendental-spec.md` for the design. Each op is graded two ways:
the standalone engine vs a C reference, and through the core vs an oracle.

## The oracle split

- **Group B — F2XM1 / FPATAN / FYL2X / FYL2XP1** — qemu computes these with
  deterministic softfloat, so they are **bit-exact vs qemu-i386**. The reference
  `tools/p5xtrans/qref.c` is a verbatim port of qemu's helpers; `qref_validate.py`
  proves it reproduces the *actual* pinned `qemu-i386` bit-for-bit (asm sweep →
  `gen_trace --x87`, all 4 rounding modes).
- **Group A — FSIN / FCOS / FSINCOS / FPTAN** — qemu computes these via the host's
  glibc at **double precision**, so qemu is not the oracle. They are **bit-exact vs
  a shared-polynomial silicon model** (`qref` octant reduction + Taylor, all
  floatx80 ops), whose accuracy is ~1.8 ulp vs `__float128` quad (`qref --validate-trig`).

## Gates

| Script | What it checks |
|--------|----------------|
| `run-f2xm1-gate.sh` / `run-fpatan-gate.sh` / `run-fyl2x-gate.sh` | standalone engine vs `qref` (qemu-bit-exact), all 4 RC |
| `run-fsincos-gate.sh` | standalone FSIN/FCOS engine vs the qref shared-poly model (+ re-checks model accuracy) |
| `run-f2xm1-core-gate.sh` / `run-fpatan-core-gate.sh` / `run-fyl2x-core-gate.sh` | the op THROUGH the core (decode → `S_TRSC_BUSY` → commit), func-exact vs the qemu gdbstub golden (`compare.py --mode func`: st0..st7 / fctrl / fstat / ftag) |
| `run-fsincos-core-gate.sh` (`fsincos_core_check.py`) | FSIN/FCOS/FSINCOS/FPTAN through the core, st0(+st1) bit-exact vs the model; reports the core-vs-qemu spread (≈1000 ulp — qemu's double precision) |

The `*-gate.sh` scripts build a small Verilator TB (`tb_*.sv`); the `*-core-gate.sh`
scripts build the cosim TB with `+VEN_TRANSCENDENTAL` (`make -C verif/tb
VL_EXTRA_DEFINES=+define+VEN_TRANSCENDENTAL OBJDIR=obj_dir_trsc`) and run
`tests/tx_*`. The default build never decodes these ops (they stay `d_unknown` →
HALT), so `make verify` stays 77/77 byte-identical.

## Quick run

```sh
bash verif/trsc/run-f2xm1-gate.sh        # + fpatan / fyl2x / fsincos
bash verif/trsc/run-fpatan-core-gate.sh  # in-core, vs qemu golden
make -C tools/p5xtrans qref-validate     # qref C refs vs qemu-i386 (F2XM1 + FPATAN)
```
