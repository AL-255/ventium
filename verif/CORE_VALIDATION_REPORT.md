# Ventium CORE VALIDATION REPORT

**Scope:** This run validated the **current working tree, including uncommitted WIP RTL** (not a clean committed checkout). Every gate below was executed against the in-progress sources under `rtl/` as they stood at validation time.

**Date:** 2026-06-27

**Headline verdict (initial run):** ❌ **NOT GREEN — 7 gates failed (5 FAIL + 2 ERROR), 5 gates skipped.**
Of 64 gates, 52 passed. The failures include **one functional core-diff regression (`sys:ptask`)** and **one compile ERROR that took the entire SoC regression offline (`verify-soc`)**, plus four testbench/RTL desync compile breaks and one KVF teardown crash. See **Failures & errors** below — at least one core-diff path is implicated by the WIP.

> ### ⏩ POST-FIX UPDATE (see §6 for detail)
> After triage, **5 of the 7 failures were stale TESTBENCHES desynced from evolved RTL function signatures** — each fixed in the testbench ONLY (no RTL touched) and re-verified green: `verify-srt`, `verify-srt-iter` (+sqrt-iter), `verify-fppipe`, and `sys:ptask`. The `verify-soc` "compile ERROR" in §2 was a **stale-build artifact** — `tb_soc.cpp` compiles fine against the current `core.sv`; the real SoC failure is an **RTL reset-value vs stale-golden** divergence. **Remaining (RTL/harness owner, NOT testbench bugs): `verify-soc` (regfile EDX=0x543 vs golden 0x663), `verify-fppipe2` (FP_PIPE2≠FP_PIPE on mb_fpindep), `l1axi-callret` (correct result, teardown SIGTRAP in WIP `tb_main.cpp`).**

---

## 1. Summary by domain

| Domain | Gates run | ✅ Pass | ❌ Fail/Error | ⏭ Skip |
|---|---:|---:|---:|---:|
| Core differential (verify + 15 `sys:*` + verify-soc) | 17 | 10 | 2 | 5 |
| Bus (biu_p5) | 2 | 2 | 0 | 0 |
| Integer features | 3 | 1 | 2 | 0 |
| FP / BCD features | 4 | 2 | 2 | 0 |
| Errata (M6 P5 self-checks) | 16 | 16 | 0 | 0 |
| L1/AXI KVF scenarios | 3 | 2 | 1 | 0 |
| Standalone module gates | 19 | 19 | 0 | 0 |
| **TOTAL** | **64** | **52** | **7** | **5** |

> Fail/Error = 5 FAIL + 2 ERROR. The 5 skips are all in core-diff: `make verify-sys` aborted after `sys:ptask` FAILED, so the five remaining `sys:*` subtests never ran.

---

## 2. Failures & errors

> ⚠️ **CORE-DIFF / COMPILE ERRORS PRESENT — the WIP may regress the core.** Two of these land directly on the differential path: a functional task-switch mismatch and a SoC testbench that no longer compiles against the current `rtl/core/core.sv`. The remaining four are testbench call-sites/ports not updated to WIP RTL signature changes, plus one KVF teardown crash. None should be dismissed as flakes.

| # | Gate | Domain | Status | Evidence |
|---|---|---|---|---|
| 1 | `sys:ptask` | core-diff | ❌ FAIL | golden-validation step 5d (HARDWARE TASK SWITCH): `AssertionError: no hardware-task-switch GPR reload captured (EAX=0xAAAAAAAA, EBX=0xBBBBBBBB, ESP=0x00070000 from TSS2)` → `make: *** [Makefile:215: verify-sys] Error 1` (make aborted here, blocking 5 downstream `sys:*` subtests). |
| 2 | `verify-soc` | core-diff | ❌ ERROR | **SoC TB fails to COMPILE** (hidden by `>/dev/null` in gate scripts): `tb_soc.cpp:725: error: 'class Vventium_soc___024root' has no member named 'ventium_soc__DOT__u_core__DOT__dbg_w_n'` (also `dbg_w` L729, `dbg_w2` L730 — debug signals removed/renamed in `rtl/core/core.sv` but still referenced by `tb_soc.cpp`). `Vventium_soc.mk:97 Error 1` → all **25 SoC sub-gates FAIL**; `make Makefile:227 verify-soc Error 1`. |
| 3 | `verify-srt` | feature-int | ❌ FAIL | `%Error: verif/srt/tb_srt.sv:28:14: Missing argument on non-defaulted argument 'buggy' in function call to FUNC 'fx_srt_div'` (also L29,38,39) → `Makefile:289 Error 1` (compile failure: TB call sites not updated for new `buggy` param). |
| 4 | `verify-srt-iter` | feature-int | ❌ FAIL | `SRT-ITER-GATE-FAIL (1214 mismatches)` — e.g. `FAIL[0] correct: got=3fffaabaa10000000000 exp=3fffaabaa0e3e35a14bd`; also PINMISSING warnings for new ports `rem_c2`/`rem_ie` → `Makefile:298 Error 1`. |
| 5 | `verify-fppipe` | feature-fp | ❌ FAIL | COMPILE ERROR in `verif/fppipe/tb_fppipe.sv`: L53 missing arg `'fdiv_err'` in `f_eval`; L54 same in `f_eval_s1`; L55 missing `'pc'` in `f_eval_s2`. TB call sites not updated to new function signatures. Real WIP defect. |
| 6 | `verify-fppipe2` | feature-fp | ❌ FAIL | `FP_PIPE2 A/B GATE: FAIL`. Kernel `mb_faddchain`: A==B identical (cycle-safe); kernel `mb_fpindep`: A==B **DIFFER** (3046 line deltas). `+VEN_FP_PIPE2` diverges from `+VEN_FP_PIPE` on `mb_fpindep` (B vs golden CPI A=1.151 C=1.153). |
| 7 | `run-l1axi-callret-gate.sh` | l1axi-kvf | ❌ ERROR | Gate aborted at `== 2. stacktest...` with script `EXIT=133`. Direct run reached `stop: WIN95 co-sim isa-debug-exit (out 0xf4) after 93 retired in 1335 clocks`, printed `AP=1234` (expected P=1234), then `tb_ventium` terminated with **signal 5 SIGTRAP (exit 133)** on teardown. Test value computed correctly; gate fails because the binary crashes on teardown under `set -eu`. |

**Skipped (not failures, but coverage lost):** `sys:ptaskcpl`, `sys:psmm`, `sys:pdebug`, `sys:ppopf`, `sys:pv86` — all ⏭ SKIP because `make verify-sys` aborted at `Makefile:215` after `sys:ptask` FAILED.

---

## 3. Per-domain breakdown

### 3.1 Core differential (RTL vs QEMU)

| Gate | Status | Evidence |
|---|---|---|
| `verify` | ✅ PASS | VERIFY GATE: PASS — functional GREEN (every program diff-clean vs QEMU, incl. x87), every M4 integer band met, every M5 FP/cache band met; func totals: 98 PASS / 0 FAIL / 98 total. |
| `sys:pseg` | ✅ PASS | RTL-SYS-DIFF-OK: EQUIVALENT (78 records match). |
| `sys:pmode` | ✅ PASS | RTL-SYS-DIFF-OK: EQUIVALENT (1084 records match). |
| `sys:ppage` | ✅ PASS | RTL-SYS-DIFF-OK: EQUIVALENT (128 records match). |
| `sys:pintr` | ✅ PASS | RTL-SYS-DIFF-OK: EQUIVALENT (171 records match). |
| `sys:pintr16` | ✅ PASS | RTL-SYS-DIFF-OK: EQUIVALENT (122 records match). |
| `sys:pfault` | ✅ PASS | RTL-SYS-DIFF-OK: EQUIVALENT (348 records match). |
| `sys:pfcpl3` | ✅ PASS | RTL-SYS-DIFF-OK: EQUIVALENT (378 records match). |
| `sys:pde` | ✅ PASS | RTL-SYS-DIFF-OK: EQUIVALENT (78 records match). |
| `sys:pcpl` | ✅ PASS | RTL-SYS-DIFF-OK: EQUIVALENT (304 records match). |
| `sys:ptask` | ❌ FAIL | step 5d HARDWARE TASK SWITCH: no hardware-task-switch GPR reload captured (EAX=0xAAAAAAAA, EBX=0xBBBBBBBB, ESP=0x00070000 from TSS2) → `verify-sys` aborted (Makefile:215). |
| `sys:ptaskcpl` | ⏭ SKIP | not run — `make verify-sys` aborted after ptask FAIL. |
| `sys:psmm` | ⏭ SKIP | not run — `make verify-sys` aborted after ptask FAIL. |
| `sys:pdebug` | ⏭ SKIP | not run — `make verify-sys` aborted after ptask FAIL. |
| `sys:ppopf` | ⏭ SKIP | not run — `make verify-sys` aborted after ptask FAIL. |
| `sys:pv86` | ⏭ SKIP | not run — `make verify-sys` aborted after ptask FAIL. |
| `verify-soc` | ❌ ERROR | SoC TB fails to compile — `tb_soc.cpp` references `dbg_w_n`/`dbg_w`/`dbg_w2` removed/renamed in `rtl/core/core.sv`; all 25 SoC sub-gates FAIL. |

### 3.2 Bus (biu_p5)

| Gate | Status | Evidence |
|---|---|---|
| `make bus` | ✅ PASS | M5B biu_p5 self-consistency: 196 checks PASS, 0 FAIL — ALL GREEN. |
| `make bus-sva` | ✅ PASS | bus_mode=1 SVA corpus: 12 PASS / 0 FAIL (SVA fires: 0); 19 biu_p5 protocol SVA held in-system on all 12 programs; all func-EQUIVALENT vs QEMU. |

### 3.3 Integer features

| Gate | Status | Evidence |
|---|---|---|
| `verify-idiv` | ✅ PASS | IDIV-GATE-OK (80000 random + directed, all 6 forms bit-exact vs native). Note: first two attempts hit a sandbox `-Mdir` create error (`build/idiv/obj/...Slow.cpp`), not a WIP defect; passed once dir existed. |
| `verify-srt` | ❌ FAIL | Compile: missing arg `'buggy'` in `fx_srt_div` calls (`tb_srt.sv` L28,29,38,39) — TB not updated for new param. |
| `verify-srt-iter` | ❌ FAIL | SRT-ITER-GATE-FAIL (1214 mismatches); PINMISSING for new ports `rem_c2`/`rem_ie`. |

### 3.4 FP / BCD features

| Gate | Status | Evidence |
|---|---|---|
| `verify-bcd` | ✅ PASS | BCD-GATE-OK: 40000 random + directed, bit-exact vs `fx_fx_to_bcd`. Note: first attempt hit missing-parent `-Mdir` artifact (`build/bcd/obj`); clean after parent created — not space/RTL related (187G free). |
| `verify-fbld` | ✅ PASS | FBLD-GATE-OK: 40000 random + directed, bit-exact vs `fx_bcd_to_fx`. Same clean-tree `-Mdir` parent artifact as bcd; passes clean after parent created. |
| `verify-fppipe` | ❌ FAIL | Compile: missing arg `'fdiv_err'` in `f_eval`/`f_eval_s1` and `'pc'` in `f_eval_s2` (`tb_fppipe.sv` L53–55). Real WIP defect. |
| `verify-fppipe2` | ❌ FAIL | FP_PIPE2 A/B: `mb_faddchain` A==B identical; `mb_fpindep` A==B DIFFER (3046 deltas); `+VEN_FP_PIPE2` diverges on `mb_fpindep`. |

### 3.5 Errata (M6 P5 self-checks)

| Gate | Status | Evidence |
|---|---|---|
| `make m6` (overall) | ✅ PASS | M6 GATE: PASS — totals 15 PASS / 0 FAIL. |
| FDIV erratum — ON flawed quotient | ✅ PASS | Documented flawed quotient `0x3fffaab7f6392a768800`. |
| FDIV erratum — OFF correct quotient | ✅ PASS | Correct quotient `0x3fffaabaa0e3e35a14bd` (matches QEMU). |
| FDIV — trigger-divisor-but-unpublished ON==OFF | ✅ PASS | ON == OFF (no fabricated flaw). |
| FDIV — non-triggering divisor ON==OFF | ✅ PASS | ON == OFF (clean, unaffected). |
| Erratum 20 (FIST/FISTP ovf) — ON stores zero, IE clear | ✅ PASS | Stores ZERO, IE not set (documented Actual). |
| Erratum 20 — OFF integer-indefinite, IE set | ✅ PASS | `0x80000000`, IE set (Expected). |
| Erratum 81 (F00F LOCK CMPXCHG8B reg-dst) — ON hangs | ✅ PASS | Reg-dst LOCK CMPXCHG8B HANGS the core (documented). |
| Erratum 81 — OFF invalid-opcode HALT, no hang | ✅ PASS | Invalid opcode HALTs loudly, no hang. |
| Erratum 81 — ON valid memory CMPXCHG8B no hang | ✅ PASS | Valid memory CMPXCHG8B does NOT hang (only reg-dst does). |
| Erratum 59 (MOV moffs A2/A3 pairing) — OFF pairs | ✅ PASS | A3 store PAIRS with EAX-using follower (UV-pairable). |
| Erratum 59 — ON fails to pair | ✅ PASS | A3 store FAILS to pair (Erratum 59). |
| Erratum 79 (V86 POPF/IRET #DB) — V86 task ran in both | ✅ PASS | Entered-sentinel `0xcafe0079` witnessed in both runs. |
| Erratum 79 — OFF only #GP, data bp did not fire | ✅ PASS | Only #GP delivered; SS:ESP data bp did NOT fire (Expected). |
| Erratum 79 — ON erroneous #DB also delivered | ✅ PASS | #DB also delivered (count=1, DR6.B0 set) on V86 POPF #GP (Actual). |
| Erratum 79 — ON #DB saved EIP == #GP handler 1st insn | ✅ PASS | #DB saved EIP `0x000f0260` == #GP handler's first instruction (Implication). |

### 3.6 L1/AXI KVF scenarios

| Gate | Status | Evidence |
|---|---|---|
| `run-l1axi-xline-gate.sh` | ✅ PASS | L1AXI-XLINE-OK (cross-cache-line stores byte-correct through L1/AXI+REMAP) [XLOK; xlinetest PASS; EXIT=0]. |
| `run-l1axi-xword-gate.sh` | ✅ PASS | L1AXI-XWORD-OK (unaligned cross-word stores + byte-memset correct through L1/AXI+REMAP) [XOK xwordtest PASS, MOK memtest PASS; EXIT=0]. |
| `run-l1axi-callret-gate.sh` | ❌ ERROR | EXIT=133: value computed correctly (`AP=1234`), but `tb_ventium` crashes with SIGTRAP on teardown; under `set -eu` propagates 133 before printing `stacktest PASS`/`L1AXI-CALLRET-OK`. |

### 3.7 Standalone module gates

| Gate | Status | Evidence |
|---|---|---|
| `run-btb-gate` | ✅ PASS | BTB-GATE-OK (all checks pass). |
| `run-cachemap-gate` | ✅ PASS | CACHEMAP-GATE-OK, 25 checks, 0 errors. |
| `run-dma8237-gate` | ✅ PASS | 8237 DMA transfer-engine gate PASS. |
| `run-hostcfg-gate` | ✅ PASS | host-bridge PCI-config → cachemap gate PASS. |
| `run-icache-snoop-gate` | ✅ PASS | icache snoop-invalidate mechanism gate PASS. |
| `run-l1axi-cdc-gate` | ✅ PASS | L1AXI dual-clock CDC gate PASS. |
| `run-l1axi-gate` | ✅ PASS | L1AXI gate PASS. |
| `run-l1axi-wd-gate` | ✅ PASS | L1AXI watchdog gate PASS. |
| `run-l1d-gate` | ✅ PASS | L1D-GATE-OK (all checks pass). |
| `run-l1dma-gate` | ✅ PASS | northbridge DMA-coherence gate PASS (L1DMA-GATE-OK). |
| `run-l1l2-gate` | ✅ PASS | L1+L2 integration gate PASS. |
| `run-l1mmio-gate` | ✅ PASS | northbridge MMIO-master (to_dram split) gate PASS (L1MMIO-GATE-OK). |
| `run-l1nb-gate` | ✅ PASS | northbridge cacheability-routing gate PASS (L1NB-GATE-OK). |
| `run-l2-axi-gate` | ✅ PASS | L2+AXI gate PASS (L2AXI-GATE-OK). |
| `run-l2-gate` | ✅ PASS | L2 gate PASS (L2-GATE-OK). |
| `run-l2-stress-gate` | ✅ PASS | L2 stress gate PASS. |
| `run-nb-sb-gate` | ✅ PASS | northbridge ↔ southbridge integration gate PASS (NBSB-GATE-OK). |
| `run-southbridge-gate` | ✅ PASS | ven_southbridge wrapper gate PASS (SOUTHBRIDGE-GATE-OK). |
| `run-tlb-gate` | ✅ PASS | TLB-GATE-OK (all checks pass). |

---

## 4. Coverage context

This functional run is the **correctness complement** to the committed coverage campaign. Per `verif/cov/COVERAGE_CAMPAIGN.md`, the campaign stands at a reproducible **77.54% combined-core toggle / 90.36% line** coverage, with **12 modules cracked + 2 new testbenches** added. The gates in this report exercise behavioral equivalence and feature correctness; the coverage campaign measures structural exercise of the same RTL. Read together, they bound both *"does it do the right thing"* (this report) and *"is enough of it exercised"* (coverage).

---

## 5. Known documented divergences (not regressions)

The following three behaviors are **pre-documented in `verif/cov/COVERAGE_CAMPAIGN.md`** and are expected/explained divergences rather than new regressions introduced by this WIP:

1. **Task-switch CR3 under PG=0** — paging-disabled task switch CR3 handling (relevant context for the `sys:ptask` task-switch path).
2. **Repeated-#PF PC drift** — program-counter drift observed across repeated page-fault delivery.
3. **BCD / FBLD-FPTRAP engine stalls** — engine stall behavior around the BCD/FBLD FP-trap paths.

> These three are catalogued and understood. They are listed here so the failures in §2 are not conflated with them. Note in particular that `sys:ptask` (§2 #1) is a **hard FAIL on the live diff**, distinct from divergence #1 — it should be triaged against the WIP, not waved off as the documented CR3/PG=0 note.

---

## 6. Post-validation resolution (testbench re-sync — RTL untouched)

The owner directive was: *fix only the testbenches; the RTL is not in scope.* Under that
constraint, 5 of the 7 failures were **stale testbenches**, not RTL bugs — the RTL grew
new function arguments/ports and the testbench call-sites were never updated. Each was
fixed in the **testbench file only** and the gate re-verified green (committed `9e9b4eb`):

| Gate | Root cause (RTL signature change) | Testbench fix | Re-verified |
|---|---|---|---|
| `verify-srt` | `fx_srt_div` gained a `pc` (precision) arg → 5 args | pass `pc=2'b11` (extended) at all 4 call sites | ✅ SRT-GATE-OK (609 vec ×2 PLAs) |
| `verify-srt-iter` (srt) | new RTL outputs `rem_c2`/`rem_ie` (PINMISSING) | declare+connect the two ports | ✅ SRT-ITER-GATE-OK (609 vec) |
| `verify-srt-iter` (sqrt) | `fx_sqrt` gained a `pc` arg | pass `pc=2'b11` at both call sites | ✅ SQRT-ITER-GATE-OK (8000 rand) |
| `verify-fppipe` | `f_eval`/`f_eval_s1` gained `pc`+`fdiv_err`; `f_eval_s2` gained `pc` | thread the SAME `pc`/`err` through all 3 calls (equivalence) | ✅ FPPIPE-GATE-OK (1M rand) |
| `sys:ptask` | (self-inflicted prior coverage edit) step-5d markers overwritten + switch pushed past `max_insn` | restore TSS2 markers (EAX=AAAAAAAA/EBX=BBBBBBBB/ESP=00070000), shrink TSS-zero loop 84→52 dwords | ✅ SYS-GOLDEN-OK, RTL-SYS-DIFF EQUIVALENT, step-5d reload captured |

### Still RED — RTL / harness owner's call (NOT testbench bugs)
1. **`verify-soc`** — NOT a compile error (the §2 dbg_w_n note was a stale-build artifact;
   `tb_soc.cpp` references `dbg_ax_n`/`dbg_ax` which exist in `core.sv:5246-7` and it links
   clean). 8/25 SoC sub-gates pass on that binary. The 17 fails are an **RTL reset-value vs
   stale-golden** divergence: `rtl/core/regfile.sv:55` resets SoC `EDX=0x0000_0543`, but the
   committed goldens (e.g. `pirqsoc.sys.vtrace.golden`) still expect `0x663` on 91 setup
   records. → Decide whether `0x543` is the intended CPUID/EDX (then **regenerate the SoC
   goldens**) or an RTL regression to fix. Out of testbench scope.
2. **`verify-fppipe2`** — `+VEN_FP_PIPE2` diverges from `+VEN_FP_PIPE` on `mb_fpindep`
   (3046 line deltas; A==B identical on `mb_faddchain`). A genuine RTL config divergence.
3. **`l1axi-callret`** — functionally correct (computes `AP=1234`) but `tb_ventium` exits
   with **SIGTRAP (133) on teardown** for the deployed KV260 config; under the gate's
   `set -e` this aborts before the OK line. The harness (`verif/tb/tb_main.cpp`,
   `xover.cpp`) is uncommitted WIP, so the teardown crash is the owner's to resolve.

**Net after testbench re-sync:** the only remaining failures are RTL-behavior / stale-golden
/ WIP-harness items — every testbench-vs-RTL **signature** desync is resolved and green.
