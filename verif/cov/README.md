<!-- Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com) -->
<!-- SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 -->

# Ventium Coverage Suite (`verif/cov/`)

`verif/cov/` drives Verilator `--coverage` (`--coverage-line --coverage-toggle`) builds of the Ventium core and leaf subsystems across complementary execution lanes while checking retired-instruction opcode execution and QEMU functional equivalence.

The coverage build always uses private object directories (`obj_dir_cov`, `obj_dir_cov_feat`, etc.), keeping the canonical `verif/tb/obj_dir/tb_ventium` binary untouched.

## Quick Start

```sh
make coverage-all    # run every lane and merge the combined CORE headline
make coverage        # user-mode ISA corpus -> line/toggle % + retired-ISA histogram + QEMU diff
make coverage-sys    # bare-metal --system images (real/PM/V86/paging/TSS/SMM/debug)
make coverage-mem    # standalone cache/AXI testbenches (ven_l1d / ven_axi_master / ventium_l1_axi)
make coverage-unit   # standalone arithmetic/bus engines (idiv / srt / sqrt / bcd / fbld / biu_p5)
make opgen           # per-opcode P54C regression suite (555 opcodes)
make opgen-modes     # real-mode / PM32-CPL0 per-opcode mode streams
```

Or invoke a runner directly:

```sh
bash verif/cov/run-cov.sh                                  # full user-mode corpus
bash verif/cov/run-cov.sh t_shift t_mul                    # selected programs only
GOLDEN=0 bash verif/cov/run-cov.sh                         # coverage only (skip QEMU diff)
COV_DEFS="+define+VEN_UOPCACHE" bash verif/cov/run-cov.sh  # widen feature flags
```

## Coverage Lanes

Verilator only instruments modules **instantiated** in a given elaboration, and `.dat` files from builds with different `ifdef VEN_*` point sets must be aggregated into matching pools rather than cross-merged blindly. `verif/cov/` organizes coverage into complementary lanes:

| Lane | Runner | Build / Top | What It Exercises |
| --- | --- | --- | --- |
| **ISA** | `run-cov.sh` | `ventium_top` (`obj_dir_cov`) | User-mode integer + x87 corpus (`verif/tests/**/manifest.json`) + retired-opcode histogram (`isa_coverage.py`). |
| **SYS** | `run-sys-cov.sh` | `ventium_top` (`--system`) | Bare-metal privileged paths: real↔PM↔V86 transitions, 4 KiB/4 MiB paging, TLB walks, IDT/TSS/call-gates, SMM/RSM, debug registers. |
| **CYC** | `run-cyc-cov.sh` | `ventium_top` (`--cycle`) | Dual-issue U+V fast pipeline (`S_PIPE`, `issue_uv`, `u_pipe`, `v_pipe`, `bpred_btb`). |
| **HALT** | `run-halt-cov.sh` | `ventium_top` | Defensive `d_unknown → S_HALT` / `#UD` default decoder arms (`verif/cov/halt/`). |
| **COSIM** | `run-cosim-cov.sh` | `ventium_top` (`--cosim`) | `CPUID`, `RDTSC`, `INVD`, `WBINVD`, and port `IN`/`OUT`/`INS`/`OUTS` (`verif/cov/cosim/`). |
| **FLAGS** | `run-flags-cov.sh` | `ventium_top` (`obj_dir_cov_feat`) | Feature-gated RTL (`VEN_UOPCACHE`, `VEN_BTB_PIPE`, `VEN_TRANSCENDENTAL`, `VEN_FPREM`, `VEN_SRT_ITER`, `VEN_IDIV_ITER`, `VEN_BCD_ITER`). |
| **FPPIPE** | `run-fppipe-cov.sh` | `ventium_top` (`+VEN_FP_PIPE/+VEN_FP_PIPE2`) | Pipelined x87 arithmetic & transcendental datapaths (`fpp2_s1`, `fpu_fpatan`, `fp_shared/` sweeps). |
| **MEM** | `run-mem-cov.sh` | Standalone `verif/l1/tb_*` + `tb_cov_l1d_sweep.sv` | `ven_l1d` (all 128 sets × 2 ways + eviction/snoop/flush), `ven_axi_master`, `ventium_l1_axi`, `ven_cachemap`, `ven_axi_cdc`. |
| **UNIT** | `run-unit-cov.sh` | Standalone unit TBs | `ven_idiv`, `fpu_srt_div`, `fpu_sqrt_iter`, `ven_bcd`, `ven_bcd_to_fp`, and `biu_p5`. |
| **SOC** | `run-soc-cov.sh` | Separate SoC pool | Legacy SoC peripheral wrappers (`ven_i8237`, `ven_uart16550`, `ven_rtc`, `ven_pit`, `ven_pic`, `ven_i8042`). |

> **Shared FPU (`fp_shared/`) Note:** On the deployed hardware profile (`c0e3fe43`, `VEN_FP_SHARED` + `VEN_FP_SHARED_DIRECT`), `fp_shared/ven_fp_top.sv` (`u_fp_shared`) and `rtl/fpu/fpu_srt_div.sv` (`u_srt`) own x87 execution; dedicated unit and system sweeps live in `fp_shared/tb/`, `verif/fppipe/`, `verif/srt/`, `verif/fpu87/`, and `verif/trsc/`.

## Per-Program Workflow (`run-cov.sh`)

1. Assemble the 32-bit ELF (`gcc -m32 -nostdlib -static`) and verify P5-only encodings (`isa_verify.py`).
2. Flatten to a raw memory blob (`elf2flat.py`) and generate/reuse the pinned QEMU golden `.vtrace`.
3. Execute `obj_dir_cov/tb_ventium` with `VEN_COV_DAT=<out>.dat` (`#if VM_COVERAGE` in `tb_main.cpp`, inert in non-coverage builds).
4. Run `verif/diff/compare.py --mode func` against the QEMU golden.
5. Run `isa_coverage.py analyze` on **retired** RTL trace records to build the executed-opcode histogram and flag any unimplemented/diverging instruction.
6. Batch-merge `.dat` files via `verilator_coverage` and emit `cov_summary.txt`/`.json`, `isa.txt`/`.json`, and annotated RTL under `build/cov/`.

## Directory Contents

| Path | Purpose |
| --- | --- |
| `run-cov.sh`, `run-sys-cov.sh`, `run-cyc-cov.sh`, `run-halt-cov.sh`, `run-cosim-cov.sh`, `run-flags-cov.sh`, `run-fppipe-cov.sh`, `run-mem-cov.sh`, `run-unit-cov.sh`, `run-all-cov.sh` | Per-lane and umbrella orchestrators. |
| `cov_summary.py` / `uncovered.py` | Parse Verilator `.dat` aggregates into per-file line/toggle tables and exact uncovered line/signal lists. |
| `isa_coverage.py` | Capstone-based retired-instruction decoder and opcode-cell histogrammer. |
| `tb_cov_l1d_sweep.sv` | Full-geometry `ven_l1d` set/way/evict/snoop/flush sweep testbench. |
| `COVERAGE_CAMPAIGN.md` | Baseline toggle/line coverage campaign methodology and reproducibility notes. |
| `opgen/` | Script-generated 555-opcode P54C differential suite (`make opgen`, `make opgen-modes`). |

> **Safeguard:** Coverage percentages measure structural RTL exercise, **never** architectural acceptance or gameplay performance. Keep `TMPDIR=/home/yukidama/external/tmp` and `VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator` set on the maintainer host.
