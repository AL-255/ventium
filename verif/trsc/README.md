# `verif/trsc/` — x87 Transcendental Verification Gates

`verif/trsc/` verifies Ventium's eight x87 transcendental instructions (`+define+VEN_TRANSCENDENTAL`, `docs/m11-transcendental-spec.md`) both at the engine leaf level and end-to-end through the core.

> **Hardware Architecture Note:** In the board-qualified **`c0e3fe43`** FPGA configuration (`VEN_FP_SHARED` + `VEN_TRANSCENDENTAL`), transcendental operations execute on the shared 38-DSP polynomial & wide-multiply engine **`fp_shared/ven_fp_trans.sv`** + **`fp_shared/ven_fp_widemul.sv`** inside `u_fp_shared` (additionally covered by `fp_shared/tb/` and `verif/fppipe/`). In non-shared `+VEN_TRANSCENDENTAL` simulation builds, `rtl/core/core.sv` instantiates `rtl/fpu/fpu_{f2xm1,fpatan,fyl2x,fsincos}.sv` atop `fpu_fx_ppl` / `fpu_estdiv`. In the minimal default `make verify` build (without `+VEN_TRANSCENDENTAL`), transcendental opcodes halt loudly (`make x87b`).

## Dual-Group Oracle Split

- **Group B — `F2XM1`, `FPATAN`, `FYL2X`, `FYL2XP1`:** Pinned `qemu-i386` evaluates these deterministically in SoftFloat, so RTL is checked **bit-exact vs QEMU** across all 4 rounding modes (`RC`). `tools/p5xtrans/qref.c` ports QEMU's exact helper algorithms (`make -C tools/p5xtrans qref-validate` proves bit-for-bit parity against `qemu-i386`).
- **Group A — `FSIN`, `FCOS`, `FSINCOS`, `FPTAN`:** QEMU 8.2.2 evaluates trigonometric ops via host `libm` at 53-bit `double` precision (`~1000` ulp error in `floatx80`), so QEMU cannot serve as an 80-bit trig oracle. Instead, RTL is verified **bit-exact against `qref`'s `floatx80` octant-reduction + polynomial silicon model**, whose accuracy is validated to `~1.8` ulp against `__float128` (`qref --validate-trig`).

## Gate Scripts

| Script | Scope |
| --- | --- |
| `run-f2xm1-gate.sh` / `run-fpatan-gate.sh` / `run-fyl2x-gate.sh` | Standalone Verilator leaf TB (`tb_*.sv`) vs `qref` across all 4 rounding modes. |
| `run-fsincos-gate.sh` | Standalone `FSIN`/`FCOS`/`FSINCOS`/`FPTAN` engine TB vs `qref` polynomial model (+ `__float128` accuracy self-check). |
| `run-f2xm1-core-gate.sh` / `run-fpatan-core-gate.sh` / `run-fyl2x-core-gate.sh` | In-core execution (`OBJDIR=obj_dir_trsc`, `+define+VEN_TRANSCENDENTAL`) diffed bit-exact against `qemu-i386 --x87` (`compare.py --mode func`: `st0..st7`, `fctrl`, `fstat`, `ftag`). |
| `run-fsincos-core-gate.sh` (`fsincos_core_check.py`) | In-core `FSIN`/`FCOS`/`FSINCOS`/`FPTAN` verified bit-exact (`st0` and `st1`) against `qref`. |

## Quick Run

```sh
bash verif/trsc/run-f2xm1-gate.sh
bash verif/trsc/run-fpatan-gate.sh
bash verif/trsc/run-fyl2x-gate.sh
bash verif/trsc/run-fsincos-gate.sh
bash verif/trsc/run-fpatan-core-gate.sh
make -C tools/p5xtrans qref-validate
```
