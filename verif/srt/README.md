# Radix-4 SRT Divider, Square-Root & Remainder Verification (`verif/srt/`)

`verif/srt/` verifies Ventium's genuine Pentium radix-4 SRT floating-point division, square-root, and exact `FPREM`/`FPREM1` engines, both as standalone unit testbenches and integrated inside the core / shared x87 FPU (`fp_shared/`).

## Hardware & Simulation Architecture (Nov 2026)

Both SRT implementations are **IEEE-754 correctly rounded** across all four rounding modes (`RC`) and all three x87 precision controls (`PC24`/`PC53`/`PC64`), and both reproduce the documented 1994 Pentium `FDIV` PLA flaw from first principles when `buggy=1`:

1. **`fpu_x87_pkg::fx_srt_div` (`make verify-srt`):** Unrolled combinational radix-4 SRT reference function used by the minimal default simulation build (`make verify` when `+VEN_SRT_ITER` is off).
2. **`rtl/fpu/fpu_srt_div.sv` (`make verify-srt-iter`, `make verify-fprem`):** Synthesizable 1-step-per-clock iterative carry-save radix-4 SRT engine unifying **`FDIV`**, **`FSQRT`**, and **`FPREM`/`FPREM1`**. Instantiated as **`u_srt` inside `fp_shared/ven_fp_top.sv` (`u_fp_shared`)** in the deployed **40 MHz STA-closed `c0e3fe43` FPGA image** (`+define+VEN_FP_SHARED +define+VEN_SRT_ITER +define+VEN_FPREM`), and as `u_srt_div` in `rtl/core/core.sv` in non-shared `+VEN_SRT_ITER` builds.

### Pentium Radix-4 SRT Datapath & First-Principles `FDIV` Bug

Modeled after the reverse-engineered Pentium P5 silicon PLA (Ken Shirriff, Dec 2024; Coe, Tang & Edelman, *SIAM Review* 39(1), 1997):

- **Radix-4 carry-save recurrence:** 2 quotient bits/step from digit set `{-2, -1, 0, +1, +2}`, partial remainder held in ones-complement `(sum, carry)` form with delayed `+1` carry-LSB injection on complemented subtracts, and remainder-sign-aware final sticky/rounding to 64-bit `floatx80`.
- **Clean vs Buggy PLA:** With `buggy=0` (hardware default), all PLA entries are populated and results are **bit-exact vs Berkeley SoftFloat-3e and QEMU**. With `buggy=1` (`+define+VEN_SRT_FDIV_BUG`), the five unprogrammed `+2 → 0` cells (`8·P_Bad ∈ {23,27,31,35,39}` in divisor columns `D ∈ {17,20,23,26,29}/16`) emerge naturally at iteration 8 without special-casing any operand:
  - `4195835 / 3145727` (`D=23`): clean `0x3FFF_AABAA0E3E35A14BD` (`1.3338204491...`) vs buggy `0x3FFF_AAB7F6392A768638` (`1.3337390689...`).
  - `5505001 / 294911` (`D=17`): reproduces the second famous PLA-foothold flaw; non-foothold pairs (`7654321 / 3145727`, `4195835 / 3.0`) remain bit-exact.

## Primary Make Gates

| Make Target | Script | What It Verifies |
| --- | --- | --- |
| `make verify-srt` | `run-srt-gate.sh` (`tb_srt.sv`) | Regenerates golden vectors from `tools/srt/srt_model.py` (`gen_vectors.py`) and checks `fpu_x87_pkg::fx_srt_div` bit-exact across both clean and buggy PLAs (`SRT-GATE-OK`). |
| `make verify-srt-iter` | `run-srt-iter-gate.sh` + `run-sqrt-iter-gate.sh` | Clocked Verilator `--timing` gates proving `rtl/fpu/fpu_srt_div.sv` (`tb_srt_iter.sv`, both PLAs) and `tb_sqrt_iter.sv` are bit-exact against the golden model (`SRT-ITER-GATE-OK`, `SQRT-ITER-GATE-OK`). |
| `make verify-fprem` | `run-fprem-gate.sh` | Full-core `tx_fprem` differential vs pinned QEMU across all 3 remainder configurations: default `fpu_fprem`, unified `+VEN_SRT_ITER +VEN_FPREM`, and deployed full-P5 `l1axi_kv_full` (`--l1-axi`). |

## Extended Shared-FPU Remainder & Waiting-`#MF` Suites

`verif/srt/` also contains the October 2026 miter and whole-core harnesses that qualified `fpu_srt_div.sv` inside `u_fp_shared` before `c0e3fe43` hardware sign-off:

- **Exact `FPREM`/`FPREM1` & Subnormal Normalization (`run_remainder_exact.py`, `tb_remainder_exact.sv`):** Verifies `8,448` multi-step partial/complete reduction sequences (`266,880` steps), including `|A| < |B|` nearest-quotient `Q=1` (`FPREM1(1.5, 2.0) = -0.5`) and normalized subnormal mantissa/exponent alignment.
- **Operand-Exception Priority (`run_remainder_exceptions.py`, `tb_remainder_exceptions.sv`):** Verifies `9,552` cases covering unsupported `floatx80` encodings, `SNaN`/`QNaN` payload selection, `IE` before `DE` priority, masked `DE`, unmasked `IE`/`DE` operand/quotient-flag preservation (`C1=0`, prior `C0/C2/C3` kept), and masked empty-stack `C2=0`.
- **Exact Tiny-Result Underflow (`run_remainder_underflow.py`, `run_remainder_underflow_sequences.py`):** Verifies Intel Vol. 3 exact-remainder underflow rules (`7,104` single-step + `2,880` partial-reduction cases): when `UM=0`, nonzero tiny remainders scale by `2^24576` in `ST_RNORM` and raise `UE` (without spurious `PE`), including zero-quotient tiny-`A` bypasses.
- **Strict Waiting-Instruction `#MF` Delivery (`run_underflow_delivery.py`, `run_strict_mf_waiters.py`, `audit_strict_mf_waiters.py`):** Under `+define+VEN_X87_MF_STRICT` (also gated by `make x87trap`), verifies pending `#MF` delivery and `#NM > #MF` priority (`CR0.TS`/`EM`) across **29 waiting x87 instruction forms** (`FWAIT`, `FNOP`, `FLD*`, `FILD*`, `FST*`, `FIST*`, `FADD`/`FSUB`/`FMUL`/`FDIV`, `FCOM`/`FUCOM`/`FTST`, `FLDCW`, `FCHS`/`FABS`/`FXCH`/`FFREE`/`FINCSTP`/`FDECSTP`) at AXI delays `0/7/31` in `--system --cosim --cycle-func --l1-axi --x87` mode with active U+V pairing.

> **Safeguard:** Use private scratch directories under `/home/yukidama/external/tmp` (`TMPDIR`) and `/tools/verilator/v5.046/bin/verilator` inside `tools/build_scope.sh`; never overwrite canonical `verif/tb/obj_dir`.
