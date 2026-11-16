<!--
Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
-->
# RTL Structural Coverage Campaign (`verif/cov/`)

Historical baseline record of the Verilator line and toggle coverage campaign on the Ventium P5/P54C core and standalone memory/bus/FPU testbenches (`make coverage-all`). Every stimulus addition was verified `EQUIVALENT` against the pinned QEMU Pentium oracle (or its standalone module self-check) without modifying in-progress RTL or weakening comparator masks.

> **Scope Note (Nov 2026):** Structural coverage complements — and never replaces — differential correctness (`make verify`, `make verify-sys`, `make l1`, `make bus bus-sva`, `make lint`) and the physical standard suite on `main` (`c0e3fe43`: CoreMark `2.100128 / 2.106796 CM/MHz`, cold Win95 OSR2 GUI + shutdown, cold DOS Quake `demo1` `8.0 FPS` at **`0.515778001` total U+V / `0.397847833` primary/U gameplay IPC** across cycles `28,696,827,616–32,989,404,795`).

## Reproducible Baseline (`run-all-cov.sh`)

- **Combined-core toggle coverage:** `70.58%` → **`77.54%`** (`+6.96` pp); **line coverage:** `89.28%` → **`89.85%`** (`~92.0%` on default `rtl/core`).
- **12 standalone-TB RTL modules** raised from `14–69%` to **`60–100%` toggle** via geometry-matched sweeps.
- **2 dedicated unit testbenches added** (`tb_tlb`, `tb_btb`) for core-internal arrays.

### Harness Fixes Required for Clean Reproducibility

1. **Per-test `--max-insn` budgets in `verif/cov/opgen/run-modes.sh`:** Long protected-mode sweeps (`pm32_segbase`, `pm32_sysregs`, `pm32_intsweep`, `pm32_paging4k`) previously truncated at `--max-insn 120`; raising their budget to `4000` (with natural `out 0xf4` exit parity) recovered `+0.86%` combined core toggle (`74.08%` → `74.94%`).
2. **Dedicated `FP_PIPE` lane (`verif/cov/run-fppipe-cov.sh`):** `cov-feat` omitted `+VEN_FP_PIPE`, leaving split-pipe registers (`fpp2_s1`) and pipelined `fpu_fpatan` paths dark (`42.6%` → `77.4%`, adding `+2.60%` combined toggle to `77.54%`).

## Per-Module Coverage Gains

| Subsystem / Module | Toggle % | Stimulus Strategy |
| --- | --- | --- |
| `ven_l1d` | `30.7% → 92.7%` | Walking-data set/way/tag + fill/invalidate/snoop sweep (`tb_cov_l1d_sweep.sv`) |
| `biu_p5` | `63.3% → 93.0%` | Pipelined ADS/NA, `BOFF#`, and snoop-writeback sweep |
| `ven_l2` (legacy standalone) | `63.6% → 86.7%` | Buffer + cross-line straddle second-line write path |
| `ven_axi_master` | `36.9% → 68.9%` | Dirty-eviction bursts + misaligned non-cacheable straddles |
| `ven_cachemap` | `36.5% → 87.5%` | 430FX PAM/TOM/SMRAM/DRAMC region-attribute diversity |
| `ven_hostbridge_cfg` | `19.9% → 90.4%` | PCI configuration-space write sweep |
| `icache` | `14.5% → 75.6%` | Full fill, read, touch, and physical-tag snoop breadth |
| `ven_axi_cdc` / `ven_cdc_afifo` | `68.9% → 86.1%` / `86.6% → 96.8%` | Walking address/data patterns across asynchronous clock ratios |
| `tlb.sv` (`tb_tlb`) | `47.0% → 91.8%` | Fill/lookup/flush with walking VPN, PFN, and permission bits |
| `bpred_btb.sv` (`tb_btb`) | `55.0% → 75.2%` | Diverse tag allocation + 2-bit bimodal counter saturation both ways |
| `fpu_fpatan` | `42.6% → 77.4%` | Dense `atan2(y, x)` octant/CORDIC/ROM sweep under `FP_PIPE` |
| `core.sv` system datapaths | `+6.96` pp core | `pm32_segbase`, `pm32_sysregs` (`CR3`/`CR4`/`LGDT`/`LIDT`/`DR0–DR7`), `pm32_segsel`, `pm32_ltr`, `pm32_intsweep` |

## Historical Findings & Subsequent Disposition

1. **Task-switch `CR3` reload under `CR0.PG=0`:** Surfaced an oracle difference where QEMU softmmu skips `TSS.CR3` reload when paging is disabled while RTL loads `TSS.CR3`; tracked across `ptask` / `ptaskpg`.
2. **Page-fault restart & cross-page fragment precision:** Addressed in the dedicated fragment-engine and fetch-boundary suites (`pxfrag`, `pxc04*`, `pfetchpc`, `pfetchbound`, `pv86movrestart`).
3. **Iterative `BCD`/`FBLD` & shared x87 FPU coverage:** In the deployed hardware architecture (`VEN_FP_SHARED`), `fp_shared/ven_fp_top.sv` (`u_fp_shared`) owns `FBLD`/`FBSTP`, `FRNDINT`, `FPREM`/`FPREM1`, `fpu_srt_div`, and polynomial transcendentals (`ven_fp_trans`), verified by `make verify-bcd`, `make verify-fbld`, `fp_shared/tb/`, `verif/fppipe/`, and `verif/srt/`.

## Structurally Unreachable Residual in Plain `ventium_top`

- Reset-only valid clears without runtime invalidation (`btb_val` 1→0 outside reset), high TSC/PMU counter bits (`2^N` cycles), constant high code-segment/EIP bits in small flat binaries, reserved architectural `EFLAGS`/`DRn` bits, and compile-time mutually exclusive `ifdef VEN_*` arms.

## Methodology

1. Merge per-lane `.dat` files (`run-all-cov.sh`) and rank untoggled signal clusters with `cov_summary.py` and `uncovered.py`.
2. Match stimulus geometry to the RTL storage/datapath (walking bit patterns, set/way/bank indices, cross-line/cross-page boundaries, valid descriptor diversity).
3. Verify every added test `EQUIVALENT` against the pinned QEMU Pentium oracle (or SDM witness gate) before keeping it.
