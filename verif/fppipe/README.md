# Pipelined & Shared x87 FPU Datapath Gates (`verif/fppipe/`)

`verif/fppipe/` contains standalone equivalence miters and whole-core A/B regressions for Ventium's pipelined x87 arithmetic execution stages (`+VEN_FP_PIPE`, `+VEN_FP_PIPE2`) and the area/DSP-optimized shared 80-bit FPU (`fp_shared/`).

## Top-Level Make Gates

| Make Target | Script | What It Verifies |
| --- | --- | --- |
| `make verify-fppipe` | `run-fppipe-gate.sh` (`tb_fppipe.sv`) | Combinational composition gate (`1M` random + corner vectors across all 4 rounding modes, precision controls, and normal/zero/Inf/NaN operands) proving `f_eval_s2(f_eval_s1(...)) == f_eval(...)` bit-exact for add/sub/mul. |
| `make verify-fppipe2` | `run-fp-pipe2-ab.sh` | Builds matched `--cycle` testbenches differing only by `+define+VEN_FP_PIPE2` (2-stage FP commit split) and verifies cycle-safe equivalence on `mb_faddchain` and `mb_fpindep` within M5 latency/throughput bands. |

## Shared FPU (`fp_shared/`) Equivalence & Overlap Harnesses

In the board-qualified **`c0e3fe43`** release (`72,204` CLB LUTs, `10,596` FFs, `2.5` BRAM36, `38` DSP48E2s in `u_fp_shared`, closed at `40.264133 MHz` post-route STA), `fp_shared/ven_fp_alu.sv` and `fp_shared/ven_fp_trans.sv` consolidate wide `floatx80` alignment, carry/multiply, and normalization cones. The scripts in `verif/fppipe/` verify those transformations without altering cycle latency or architectural state:

- **`run-shared-add-front.py` (`tb_shared_add_front.sv`):** Sequential miter (`311,557` clock edges × 3 seeds = `934,671` checked edges) proving that pre-selecting add/sub/reverse-sub operand signs before a single `fx_add_s1` front-end (while feeding unmodified operands to `f_special` for exact x87 NaN propagation) and using automatic DSP inference (`--auto-dsp`, avoiding unpipelined adder DSP cascades) matches the original `ven_fp_alu` cycle-for-cycle across all 85 result bits, busy/done handshakes, and in-flight resets.
- **`run-shared-fp-system.py`:** Whole-core `U/V + system fast-pipe` (`cycle_mode=1`, `--l1-axi` at latencies `0` and `7`) differential gate against pinned `qemu-system-i386` across streamed `FADD` + `INT3`, pending `FDIV` + queued `FXCH` + `INT3`, and streamed `FADD` + integer branch + `INT3` (`13,816` unfiltered architectural records with active V-pipe retirements).
- **`run-shared-trans-pack.py` (`prepare-shared-trans-pack.py`, `shared_trans_miter.svh`, `test_shared_trans_pack.py`):** Sequential 776,060-edge + 144-reset-phase miter for sharing `normalize_round_pack` across the six disjoint sequencer consumers inside `fp_shared/ven_fp_trans.sv`, plus reference-only non-stubbed divider/sequential-oracle generators (`prepare-trans-oracle.py`, `prepare-arch-oracle.py`, `test_trans_oracle.py`).

## Safeguards

Always run scripts with `TMPDIR=/home/yukidama/external/tmp`, `PYTHONDONTWRITEBYTECODE=1`, and `VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator` inside `tools/build_scope.sh`, writing all temporary elaborations to fresh private scratch directories (never `verif/tb/obj_dir`). Isolated leaf LUT/WNS figures are out-of-context diagnostics and never substitute for full-chip routed STA or physical Quake gameplay IPC (`0.515778001` total U+V on `c0e3fe43`).
