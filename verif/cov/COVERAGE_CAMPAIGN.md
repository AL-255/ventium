<!--
Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
-->
# RTL Coverage Campaign — Session Report

A focused campaign to raise Verilator **toggle** coverage of the Ventium P54C core
and its standalone modules, by driving each module's datapaths with input diversity
**matched to the module's actual geometry** (cache set/way/tag, descriptor fields,
register widths, AXI burst/straddle structure), as pure stimulus (no value checks
that would fail gates). Every change is verified `EQUIVALENT` vs qemu-system-i386 (or
its module gate's self-check) before commit; the user's in-progress RTL is untouched.

## Headline result (REPRODUCIBLE — re-derived by a clean `run-all-cov.sh`)
- **Combined-core toggle: 70.58% → 74.08% (+3.50 points)**, line 89.28→89.85%.
- **12 standalone-TB RTL modules** lifted from 14–69% to 60–100% toggle (reproduce via their own gates).
- **2 new standalone TBs authored** for previously TB-less core-internal modules.
- **~92 commits**, all gates green / differentials EQUIVALENT.

### Reproducibility correction (important — read this)
An earlier in-session figure of **77.46% (+6.88)** was reached by *ad-hoc folding* mode/
FP dats produced at full sweep length / on a custom FP_PIPE build. A clean `run-all-cov.sh`
re-derives only **74.08% (+3.50)** because the standard harness does NOT capture the full
sweeps:
- **run-modes uses `--max-insn 120`** (golden/RTL length-match design) — my mode sweeps
  (pm32_sysregs/segbase/segsel/ltr/intsweep, +DR/CR/seg) are hundreds of instructions, so
  only their first ~120 reproduce (e.g. seg_base 328→**113**, creg4 12→**1**). The coverage
  is REAL at full length; the harness truncates it. **Fix needed: per-test max-insn in
  run-modes** (or front-load each sweep's highest-value ops).
- **run-transc/run-flags use the cov-feat build (no `VEN_FP_PIPE`)**, where FPATAN stalls/
  takes the non-pipe path → `fpu_fpatan` reproduces at **42.6%**, not the 77.4% my custom
  `obj_dir_transc` (+FP_PIPE) build reached; `fpp2_s1` (split-pipe) doesn't appear at all.
  **Fix needed: a +VEN_FP_PIPE coverage lane** to bank the FP-pipeline + fpatan coverage.

What DOES reproduce cleanly in the standard headline: ptask tsw_gpr **506/512**, the early
parts of the system-register sweeps (creg3 39, dr0 17, dr7 13, idt_base 19, seg_sel 115,
tr_base 26), and all 12 standalone-module gates + the 2 new TBs.

## Per-area wins
| Area | Result | Method |
|---|---|---|
| ven_l1d | 30.7→92.7% | walking-data set/way/tag + fill/invalidate/snoop sweep |
| biu_p5 | 63.3→93.0% | pipelined/BOFF/snoop-model sweep |
| ven_l2 | 63.6→86.7% | buffer + cross-line straddle (second-line write path) |
| ven_axi_master | 36.9→68.9% | dirty-evict burst + misaligned-NC straddle (beat B) |
| ven_cachemap | 36.5→87.5% | 430FX config-bit (PAM/TOM/SMRAM/DRAMC) diversity |
| ven_hostbridge_cfg | 19.9→90.4% | PCI config-write sweep |
| icache | 14.5→75.6% | full fill+read+touch+snoop breadth |
| ven_i8237_dma / ven_northbridge / ventium_l1_axi | +33–42% | diverse DMA transfers + core traffic |
| ven_axi_cdc / ven_cdc_afifo | 68.9→86.1 / 86.6→96.8% | walking addr/data across clock ratios |
| **tlb.sv** (NEW tb_tlb) | 47→91.8% | fill/lookup/flush, walking vpn/pfn/perm |
| **bpred_btb.sv** (NEW tb_btb) | 55→75.2% | rich-tag alloc + counter saturation both ways |
| fpu_fpatan | 42.6→77.4% | dense atan2(y,x) sweep (CORDIC + ROM) |
| core.sv datapaths | tsw_gpr 43→506, seg_base 76→328, fpp2_s1 358→404, +CR3/CR4/IDT/GDT/DR/TR/seg_sel/IRET | system-register / descriptor / debug / task / interrupt sweeps |

New mode streams added to `verif/cov/opgen/gen_modes.py`: pm32_segbase, pm32_sysregs
(CR3/CR4/LIDT/LGDT/MOV-DR0-7), pm32_segsel, pm32_ltr, pm32_intsweep.

## ⚠ Core/qemu divergence findings (for the core owner — NOT coverage bugs)
These surfaced while extending tests into less-common paths; each is a genuine
core-vs-qemu behavioural mismatch (left unapplied to keep gates EQUIVALENT):

1. **Task-switch CR3 reload under PG=0.** On a JMP task switch with paging off, the
   core loads `TSS.CR3` into CR3 unconditionally; qemu keeps CR3=0 (skips the reload
   when CR0.PG=0). Reproduce: set a diverse `TSS.CR3` in `verif/sys/tests/ptask` →
   diverges at the switch (`field=cr3`).
2. **Repeated #PF restart PC drift.** A single #PF restart is EQUIVALENT, but after
   ~30 fault/restart cycles the core's restarted-instruction PC trace drifts from
   qemu by one instruction. Reproduce: a CR2-generic handler + diverse-address #PF
   sweep on `verif/sys/tests/pfault`.
3. **Iterative BCD/FBLD + FPATAN-FPTRAP engine stalls.** In the feature build with
   `VEN_BCD_ITER`/`VEN_FPTRAP` but no PS proxy, FBLD enters `S_FBLD_BUSY` and never
   completes (quiescent); under `--cosim` the PS bypasses the in-RTL engine, so
   `eng_bcd_result`/`eng_fbld_result`/`fptrap_result` stay 0 in all configs.

## Structurally unreachable residual (measured, not assumed)
- **No runtime-flush valid bits** (dc_val, btb_val, ic_val_o 1→0): reset-only clear.
- **Perf-counter / TSC high bits**: need 2^N events.
- **Code-segment-constant high bits** of FIP / gate offsets / EIP, reserved EFLAGS/DRn bits.
- **async SMM** (`rsm_*`): SMI-entry save-state timing not deterministically capturable.
- **SoC/cosim ports** (cosim_en, soc_en, io_*, intr/nmi, syscall_*): feature/SoC-lane (active WIP).

## Reusable methodology
1. Survey: merge all dats, list per-module/per-signal untoggled clusters.
2. For each cluster, identify the RTL mechanism that writes it (array fill, register
   load, descriptor field, datapath beat).
3. Drive it with diversity matched to that mechanism (walking bits, both directions,
   boundary-crossing, valid-but-diverse descriptors).
4. **Build and measure** — never assume "exhausted" or "divergent"; verify. This
   repeatedly converted false-negatives (tsw_gpr, seg_base, fpu_fpatan, debug regs)
   into real wins, and caught duds (diverse-CR3, repeated-#PF) before commit.
5. Yield bottoms out when the survey's remaining clusters are all structural — at
   which point further "wins" are churn that dilutes the suite.

## State at report time
The cleanly-reachable, coverage-only frontier is exhausted (verified via both the
toggle-yield trajectory +180→+10 and a line-coverage cross-check showing the same
structural signals). Further coverage requires a **core change** (the 3 findings) or
is structurally unreachable. The 30-minute cron `907917fe` continues the cadence.
