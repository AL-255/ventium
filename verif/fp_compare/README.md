# Direct x87 Compare-Invalid Classification Harness (`verif/fp_compare/`)

`verif/fp_compare/` holds the leaf equivalence miter and whole-core regression scripts for a combinational critical-path cut in `fp_shared/ven_fp_top.sv`: classifying x87 memory-compare invalid-operation (`IE` / sticky `ES` / `FSW.B`) directly from raw memory formats rather than waiting for 16/32/64-bit integer normalization into 80-bit `floatx80`.

## Design Property & Test Harnesses

- **Mathematical invariant (`prepare.py` / `tb_classifier.sv`):**
  - Signed 16/32/64-bit integer memory operands (`FICOM`/`FICOMP`) always convert to exact finite `floatx80` values and can never raise a memory-operand NaN `IE`.
  - `binary32`/`binary64` memory operands (`FCOM`/`FCOMP` m32/m64) are NaN iff `exp == all_ones && frac != 0`, without normalizing subnormals first.
  - Raw `floatx80` register/default-size forms and `FUCOM*` signaling-NaN-only semantics remain unchanged, and numeric `C3/C2/C0` condition codes continue to use the full converted operand.
- **`run_leaf.py` (`tb_classifier.sv`):** Compiles the original and transformed `ven_fp_top` compare classifiers and verifies **425,984** native comparisons across all 65,536 `int16` values, all `binary32`/`binary64` exponents with one-hot/zero fractions, 16 opcodes × 16 byte sizes × 512 random/special `ST(0)`/`ST(i)`/prior-`FSW` states, plus 4 negative-mutation checks (`SNaN` drop, false integer NaN, quiet `FUCOM` signaling, and dropped raw-`m80` fallback).
- **Whole-core & fault regressions (`build_core.py`, `run_checks.py`, `run_same_input.py`, `run_env_faults.py`, `run_smsw_corners.py`):** Exercise the isolated core candidate in `U/V + system fast-pipe` (`--cycle-func --l1-axi`) against the 108-program user corpus, 44 cold x87 environment-store `#PF` fixtures, and 223 `SMSW` system comparisons.

## Historical Disposition & Current Hardware Baseline

In its October 2026 combined next-line-tag + classifier trial synthesis, Vivado inferred `5,120` flattened `dc_tag` flip-flops instead of distributed tag RAM, regressing unplaced core timing to `32.405 MHz` (`195,562` LUTs), so that combined checkpoint was **not** promoted. Way-banked distributed tag RAM, `pf_fill_addr_rep[0..3]` fanout replication, global synthesis retiming, and `opt_design -muxf_remap` + `AlternateCLBRouting` subsequently closed true **40 MHz post-route static timing sign-off** (`40.264133 MHz`, `WNS = +0.164 ns`, `171,819` LUTs, `0` `>=85%` congestion hotspots) on **`main` release image `c0e3fe43`**, with verified physical Quake gameplay IPC of **`0.515778001` total U+V** (`0.397847833` primary/U-only) across cycles `28,696,827,616–32,989,404,795`.

Run any isolated replay in a fresh external directory (`TMPDIR=/home/yukidama/external/tmp`, `VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator`) inside `tools/build_scope.sh`; never overwrite canonical `verif/tb/obj_dir`.
