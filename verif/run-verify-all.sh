#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# run-verify-all.sh — Ventium TOP-LEVEL verification umbrella.
#
# One command that runs EVERY routinely-runnable gate and reports a single
# pass/fail summary. Until now the gates were partitioned into independent
# targets (make verify / verify-sys / verify-soc / verify-srt / m6 / bus /
# bus-sva), so a regression in (say) the bus-protocol SVA, the errata flag, or
# the SRT divider would NOT be caught by the routinely-run differential
# aggregates. `verify-all` closes that umbrella gap.
#
# Included gates: see the GATES array below — it is the SINGLE SOURCE OF TRUTH,
# and the script PRINTS it at startup and in the summary. (REVIEW_Jul29 M-03: this
# header used to carry its own hand-maintained list which had drifted out of sync
# with GATES, so the umbrella advertised a gate it never ran.)
#
# DELIBERATELY EXCLUDED (logged below, NOT silently dropped):
#   * verify-soc  — REVIEW_Jul29 M-03/M-04. The header used to list this as gate 3,
#                   but there is NO `verify-soc` make target and no runnable gate
#                   script in this checkout (verif/soc/ holds only obj_dir build
#                   artifacts). It was therefore advertised-but-never-run, while the
#                   final message still claimed every gate had passed. Restoring it
#                   is tracked with the rest of the missing-source problem (M-04).
# The m7 macro co-simulations depend on producer artifacts that are gitignored and
# cannot be regenerated from a clean checkout:
#   * m7 Quake lock-step  (needs the built Quake guest + shareware pak0.pak)
#   * m7 Win95 co-sim     (needs the rr-recorded replay.bin/overlay producer set)
# Run those manually after staging their producer inputs:
#   bash verif/m7/run-quake-lockstep.sh   /   bash verif/m7/win95/run-win95-cosim.sh
#
# Sequential (NOT parallel): the gates share build/ output dirs, the verif/tb
# obj_dirs, and gdbstub ports, so concurrent runs would race. Each gate is
# already internally parallel/cached where it can be.
#
# Exit 0 only if ALL included gates pass. Usage: bash verif/run-verify-all.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MK=(make -C "$REPO")

# name|make-target|class
# REVIEW_Aug3 M-03: every gate carries a CLASS. PASS = a correctness gate whose
# success means the behaviour is right. XFAIL-PINNED = an EXPECTED-FAILURE pin:
# the gate's success criterion is that a KNOWN, UNFIXED defect still reproduces
# (reachability evidence held so a future fix must restate the gate). A pin that
# "passes" must NOT be read as a correctness pass, and a fix must replace the pin
# with a functional regression in the same commit. COVERAGE-ONLY = reports
# coverage/reachability, proves no behaviour.
GATES=(
  "verify    (m1-m5 differential func + cycle)|verify|PASS"
  "verify-sys (M2S system-mode + RTL --system diff)|verify-sys|PASS"
  "verify-srt (radix-4 SRT divider, both PLAs)|verify-srt|PASS"
  # FPREM/FPREM1 vs the pinned QEMU golden on all three remainder-engine
  # configurations (dedicated fpu_fprem / unified fpu_srt_div rem-mode /
  # deployed-profile l1axi_kv_full). One record-scoped oracle-gap mask
  # (QEMU never fills FPREM1's quotient CCs) carried in the test's manifest.
  "verify-fprem (FPREM/FPREM1 differential, 3 engine configs)|verify-fprem|PASS"
  "m6        (documented P5 errata self-checks)|m6|PASS"
  # REVIEW2 M-09: tx_deferred_halt (the 99th corpus program) is deliberately outside
  # the differential gate and its manifest delegates coverage to run_x87_boundary.sh --
  # which nothing invoked, so it was covered by nothing. Same shape as the missing L1
  # gates below.
  "x87b      (x87 deferred-op loud-HALT boundary)|x87b|PASS"
  # REVIEW2 M-03: the A20 gate. Carries its own control (A20 ENABLED must keep the
  # 1 MiB aliases DISTINCT), so it fails both for a build with no A20 and for one
  # that masks unconditionally.
  "a20       (A20 1 MiB alias wrap via port 0x92)|a20|PASS"
  # REVIEW2_Aug1 C-06: per-access segment LIMIT enforcement. Also NOT differential --
  # QEMU does not enforce segment limits at all (pseglim exits 133 there, counter 0),
  # so a diff would fail exactly when Ventium is correct. Carries BOTH directions: the
  # violating access must raise one #GP(0) and complete, AND the check must reject
  # nothing across all 19 system tests. The negative half is the point -- this
  # finding's delivery was reverted twice for shipping false positives.
  "seg       (per-access segment limits, +/- both directions)|seg|PASS"
  # REVIEW2 M-01: FNSTENV must mask all x87 exceptions. Deliberately NOT differential
  # -- the default CW already has the mask bits set (so the corpus never reaches the
  # behaviour) and QEMU does not implement it, so a diff would fail when Ventium is
  # right. Asserted against the SDM instead.
  "fenv      (x87 FNSTENV masks all exceptions)|fenv|PASS"
  # REVIEW1_Aug3 R2-H06: the x87 stack-fault matrix. Self-checked vs the SDM
  # (QEMU implements NO stack faults -- no golden possible): func witnesses
  # (edi=0x42, ebx=7, ecx=16) + 7x vec=16 faultlog, cycle/FP_PIPE/FP_PIPE2 by
  # PC-stream identity.
  "x87stk    (x87 stack-fault matrix, R2-H06)|x87stk|PASS"
  # REVIEW2_aug2 C-03: an IDT gate offset beyond the destination CS limit must be
  # rejected DURING delivery, before CS/CPL are installed. NOT differential: the
  # harness QEMU takes a #GP here too, so a diff cannot tell the two apart. The
  # assertion is the SAVED CS on the fault frame (0x08 = rejected before install,
  # 0x18 = installed and the overrun fetch faulted) -- "a #GP happened" is true in
  # BOTH builds, which is precisely how this test's first draft passed with the fix
  # reverted. Verified to FAIL against a build with the limit compare removed.
  "intlim    (IDT gate offset vs destination CS limit)|intlim|PASS"
  # REVIEW2_aug2 C-03: a truncated TSS must raise #TS instead of reading ssN:espN from
  # past tr_limit, and that #TS must be classified at the ORIGINAL privilege. Both a
  # fixed and a broken core run to completion here, so the witness identifies WHICH
  # handler ran. An absent witness FAILS: before the CPL half was staged this chain
  # escalated #TS -> #GP -> #NP -> shutdown and reported nothing.
  "tsslim    (truncated TSS -> #TS at the original CPL)|tsslim|PASS"
  # REVIEW2_aug2 H-07: far RETF must bound its POPPED CS against the table before the
  # descriptor read. The pre-fix core raises no fault and STALLS at the LRET, so the
  # gate fails on an absent witness rather than treating it as inconclusive.
  "retfsel   (far RETF bounds its popped CS selector)|retfsel|PASS"
  # REVIEW2_aug2 C-06 (selector half): a far CALL must not push its return frame before
  # rejecting a bad selector. Witness is the ESP delta across the fault. Verified to
  # FAIL (0x0CA10008) against a build with the dispatch check removed.
  "callsel   (far CALL validates before touching the stack)|callsel|PASS"
  # REVIEW2_aug2 C-04: the directed boundary case the finding asks for. Asserts the
  # core's PAGING/C-04 assertion FIRES for all SIX non-split producers -- i.e. that
  # "0 reachable in 68 images" was corpus coverage, not architectural unreachability.
  # (History: a REVIEW_Aug3 M-03 expected-failure pin while the producers still
  # corrupted on a crossing, then an R2-C03 pin on the read-frag2 walk defect the
  # converted pxc04 exposed; both defects are fixed and the gate is the PASS-class
  # completion-form regression below.)
  # REVIEW1_Aug3 R2-C03: the fragment engine landed and the gate IS the
  # completion-form correctness regression (each producer's crossing must
  # complete differentially clean vs QEMU; the fatal must never fire). All 6/6
  # producers are GREEN: the read-frag2 S_WALK contamination the converted
  # pxc04 exposed (the walk's PDE latch sampling fx_merged) is fixed by the
  # engine's walk freeze (fx_walk_hold in rtl/core/core.sv), so the entry moves
  # to PASS (2026-08-04).
  "xc04      (page-crossing fragment engine, 6 producers)|xc04|PASS"
  # REVIEW2_aug2 H-08 + C-06: the two sequences that fail SILENTLY (NT task-return,
  # outer-level RETF) are instrumented; this gate reads the instruments so a future
  # workload reaching them is REPORTED rather than printed into a log nobody greps.
  "unimpl    (unimplemented sequences stay unreachable)|unimpl|PASS"
  # REVIEW2_aug2 C-06: a far RETF to an OUTER level must pop and VALIDATE SS:ESP.
  # The witness is the ring-3 SS, not the privilege level -- CPL takes the popped RPL
  # in the broken build too, so "did we reach ring 3" cannot see this bug.
  "retfout   (far RETF to an outer level switches stacks)|retfout|PASS"
  # REVIEW2_aug2 C-06, call-gate half: the INBOUND direction. Also covers the gate-DPL
  # bit misread that made every DPL-3 gate #GP from ring 3 -- which is why the
  # "cross-priv gate unimplemented" halt had never been seen by any corpus run.
  "callxpl   (cross-privilege call gate switches stacks)|callxpl|PASS"
  # REVIEW2_aug2 H-13: ven_cachemap landed on this branch, so instruction-fetch
  # cacheability now follows the PHYSICAL MEMORY TYPE and not CR0.CD alone.
  "mtype     (fetch cacheability follows the memory type)|mtype|PASS"
  # REVIEW2_aug2 H-13: CR0.CD drives instruction-fill cacheability in the DEFAULT build
  # now. This gate existed and nothing ran it. Asserts that the CD-honouring build
  # really refetches AND that it is architecturally transparent vs the caching build.
  "icbypass  (CR0.CD drives instruction-fill cacheability)|icbypass|PASS"
  # REVIEW2_aug2 C-07/M-02: the TSS I/O permission bitmap. Recorded as UNVALIDATED for
  # this whole review ("S_IOPERM consults corpus-wide = 0") because --soc-en never
  # reached the core. Witness is the #GP count in ecx: 6 correct, 4 with only the first
  # port of a multi-port access checked. Verified to FAIL against that reverted build.
  "ioperm    (TSS I/O permission bitmap, multi-port)|ioperm|PASS"
  # The 12 verif/l1/run-*.sh memory-subsystem gates (L1D coherence + store/load,
  # I-cache snoop, TLB, BTB, and the L1/AXI family). These existed for a long time
  # with NO make target and NO entry here, while this script's own banner called
  # itself "every routinely-runnable gate" -- so the gates covering exactly the RTL
  # that REVIEW2's cache findings touch were the ones being skipped. Adding them
  # immediately found run-l1axi-callret-gate.sh permanently broken.
  # REVIEW_Aug3 M-03 history: this used to contain an expected-failure pin --
  # run-ic-alias-gate.sh passed only while the default build exhibited the
  # linear-alias stale-icache hazard. R2-H09 fixed the hazard (physical snoop
  # tags, 2026-08-04): the gate is now a correctness gate (the fix must drop
  # the aliased line; a VEN_IC_SNOOP_LINEAR control build must reproduce the
  # hazard, so the gate provably discriminates).
  "l1        (all L1/TLB/BTB/AXI gates)|l1|PASS"
  "bus       (standalone biu_p5 protocol gate)|bus|PASS"
  "bus-sva   (integrated bus_mode SVA corpus run)|bus-sva|PASS"
  # REVIEW_Aug3 M-02: the status documents must not drift from the RTL/gates.
  "docs-status (doc halt-tags/defines/pins vs source)|docs-status|PASS"
  # the lint matrix: structural warning classes are hard errors across five
  # build configurations (default/L1AXI/KV260/BCD_ITER/FP_PS_ALL)
  "lint      (structural warning classes fatal in 5 configs)|lint|PASS"
)

declare -a NAMES RESULTS CLASSES
FAILED=0

echo "######################################################################"
echo "# Ventium verify-all — every routinely-runnable gate"
echo "######################################################################"
# REVIEW_Jul29 M-03: print the ACTUAL gate list, derived from the GATES array, so
# what this umbrella claims can never drift from what it runs again.
echo "# INCLUDED (${#GATES[@]} gates, from the GATES array):"
for entry in "${GATES[@]}"; do echo "#   - ${entry%%|*}   [make ${entry##*|}]"; done
echo "# EXCLUDED (NOT run here):"
echo "#   - verify-soc          (no such make target / gate script in this checkout — M-03/M-04)"
echo "#   - m7 Quake lock-step  (verif/m7/run-quake-lockstep.sh; needs gitignored producers)"
echo "#   - m7 Win95 co-sim     (verif/m7/win95/run-win95-cosim.sh; needs gitignored producers)"

for entry in "${GATES[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  target="${rest%%|*}"
  class="${rest#*|}"
  [[ "$class" == "$target" ]] && class="PASS"   # no class field -> PASS
  echo
  echo "==================== GATE: $name ===================="
  echo "---- make $target ----"
  if "${MK[@]}" "$target"; then
    NAMES+=("$name"); RESULTS+=("PASS"); CLASSES+=("$class")
  else
    NAMES+=("$name"); RESULTS+=("FAIL"); CLASSES+=("$class"); FAILED=1
  fi
done

echo
echo "######################################################################"
echo "# verify-all — SUMMARY"
echo "######################################################################"
NPASS=0; NPIN=0
for i in "${!NAMES[@]}"; do
  if [[ "${CLASSES[$i]}" == "PASS" ]]; then
    printf "  %-6s  %s\n" "${RESULTS[$i]}" "${NAMES[$i]}"
    [[ "${RESULTS[$i]}" == "PASS" ]] && NPASS=$((NPASS+1))
  fi
done
for i in "${!NAMES[@]}"; do
  if [[ "${CLASSES[$i]}" == "XFAIL-PINNED" ]]; then
    printf "  %-6s  %s   [XFAIL-PINNED: holds an EXPECTED failure -- NOT a correctness pass]\n" \
      "${RESULTS[$i]}" "${NAMES[$i]}"
    [[ "${RESULTS[$i]}" == "PASS" ]] && NPIN=$((NPIN+1))
  fi
done
echo
echo "  (excluded: verify-soc [absent in this checkout — M-03/M-04];"
echo "             artifact-dependent m7 Quake lock-step, m7 Win95 co-sim)"
echo
if [[ "$FAILED" == "0" ]]; then
  # REVIEW_Jul29 M-03: state exactly WHAT passed (the N gates actually run), rather
  # than the old blanket "every routinely-runnable gate PASSED" — which was untrue
  # while verify-soc was advertised in the header but missing from GATES.
  # REVIEW_Aug3 M-03: expected-failure pins are reported SEPARATELY and never
  # counted in the correctness-pass numerator.
  echo "VERIFY-ALL-OK  ($NPASS correctness gates PASSED + $NPIN expected-failure pin(s) HELD; see the EXCLUDED list above)"
  exit 0
else
  echo "VERIFY-ALL: one or more gates FAILED (see above)"
  exit 1
fi
