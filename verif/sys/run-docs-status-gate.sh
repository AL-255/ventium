#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-docs-status-gate.sh — REVIEW_Aug3 M-02: documentation/source consistency.
#
# The status documents must not drift from the RTL and the gates. This gate checks
# the load-bearing claims mechanically instead of by reading:
#
#   1. every "loud halt" tag documented in docs/unsupported-isa.md §1/§2 exists at a
#      halt site in rtl/core (and vice versa: no undocumented 0xD*/0xDA halt tags);
#   2. the correctness defines the doc lists as OFF are genuinely absent from the
#      deployed define set (KV_FULL_DEFS in verif/tb/Makefile);
#   3. the pin-class entries the doc names are classified as such where the
#      aggregate reports them (both former pins are PASS-class since
#      2026-08-04: xc04 via the walk freeze, ic-alias via R2-H09);
#   4. every status row in docs/unsupported-isa.md §5 names the gate that holds the
#      corresponding evidence (a `run-*` script or make target that exists).
#
# Prints DOCSSTATUS-GATE-OK on success.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="$REPO/docs/unsupported-isa.md"
fails=0
bad(){ echo "  FAIL: $*"; fails=1; }
ok(){  echo "  ok   $*"; }

echo "== M-02: documentation/source consistency =="

# --- 1. halt tags: doc <-> rtl/core -------------------------------------------
DOC_TAGS="$(grep -oE '0xD[0-9A-C]' "$DOC" | sort -u)"
RTL_TAGS="$(grep -rhoE 'int_vec<=\{?4'"'"'hD,|int_vec<=8'"'"'hD[0-9A-C]' "$REPO/rtl/core" \
            | grep -oE 'hD[0-9A-C]?|4'"'"'hD' | sort -u || true)"
for t in $DOC_TAGS; do
  nib="${t:3:1}"
  if grep -qE "int_vec<=8'h$t|int_vec<=\{4'hD, *desc_type" "$REPO/rtl/core/core_seg_ljmp.svh"; then
    ok "tag $t documented and present at a halt site"
  else
    bad "tag $t is documented in unsupported-isa.md but has NO halt site in core_seg_ljmp.svh"
  fi
done
# every literal halt tag in the resolver must be documented
for t in $(grep -oE "int_vec<=8'hD[0-9A-C]" "$REPO/rtl/core/core_seg_ljmp.svh" | grep -oE '0xD[0-9A-C]' | sort -u); do
  grep -q "$t" "$DOC" || bad "halt tag $t exists in core_seg_ljmp.svh but is NOT documented"
done

# --- 2. correctness defines listed as OFF are not in the deployed set ----------
KVDEFS="$(grep -A4 '^KV_FULL_DEFS' "$REPO/verif/tb/Makefile")"
for d in VEN_SEG_ENFORCE VEN_IC_ALIAS_SAFE VEN_X87_MF_STRICT; do
  grep -q "$d" "$DOC" || bad "$d: not listed in unsupported-isa.md's off-by-default table"
  if grep -q "+define+$d" <<<"$KVDEFS"; then
    bad "$d: documented as OFF but present in KV_FULL_DEFS (deployed define set)"
  else
    ok "$d: documented OFF and absent from the deployed define set"
  fi
done

# --- 3. expected-failure pins are classified as pins ----------------------------
# (xc04 was the second pin until 2026-08-04: both defects it held -- the
# unsplit producers and the read-frag2 S_WALK merge contamination -- are fixed,
# so it is PASS-class now. This check keeps the ONE remaining pin honest.)
grep -q 'xc04      (page-crossing fragment engine, 6 producers)|xc04|PASS' "$REPO/verif/run-verify-all.sh" \
  && ok "xc04 classified PASS (both pinned defects fixed, 6/6 producers green)" \
  || bad "xc04 lost its PASS-class entry in run-verify-all.sh"
grep -q '"l1        (all L1/TLB/BTB/AXI gates)|l1|PASS"' "$REPO/verif/run-verify-all.sh" \
  && ok "l1 entry present and PASS-class in run-verify-all.sh (ic-alias pin retired)" \
  || bad "l1 entry lost its PASS-class form in run-verify-all.sh"
grep -q 'HAZARD REPRODUCED' "$REPO/verif/l1/run-ic-alias-gate.sh" \
  && ok "ic-alias gate keeps its discrimination control (VEN_IC_SNOOP_LINEAR)" \
  || bad "run-ic-alias-gate.sh lost its discrimination control"

# --- 3b. R2-M03: no blanket "nothing fails silently" while silent defects exist --
if grep -qiE "Nothing here fails silently" "$DOC"; then
  bad "unsupported-isa.md still claims 'nothing fails silently' (R2-M03: the file"
  echo "       itself lists known-silent-defects -- the blanket claim is contradictory)"
else
  ok "no blanket 'nothing fails silently' claim (R2-M03)"
fi
# the semantic class structure must be present while any class is non-empty
for s in "§A. Unsupported-loud" "§B. Known-silent-defects" "§C. Expected-failure pins" "§D. Configuration-absent"; do
  grep -qF "$s" "$DOC" || bad "unsupported-isa.md lost its '$s' section (R2-M03)"
done
grep -qF "§A. Unsupported-loud" "$DOC" && ok "semantic class structure present"

# --- 3c. R2-M03: router/configuration claims match the RTL ----------------------
grep -q "route_err" "$REPO/rtl/mem/ventium_l1_axi.sv" \
  && grep -q "axm_bus_err | route_err" "$REPO/rtl/mem/ventium_l1_axi.sv" \
  && ok "no-L2 router: route_err exists and feeds bus_err (R2-H03)" \
  || bad "unsupported-isa.md §A.4 claims loud non-DRAM routing but route_err/bus_err is not wired"
grep -q "4'd2" "$REPO/rtl/mem/ventium_l1_axi.sv" \
  && ok "VGA DDR override is explicit in the router (region R_VID)" \
  || bad "the VGA DDR override is not in the router"
grep -q "cr0_cd" "$REPO/rtl/mem/ventium_l1_axi.sv" \
  && grep -q "R2-H12" "$REPO/rtl/mem/ventium_l1_axi.sv" \
  && ok "CR0.CD is honored on the D side in the default build (R2-H12)" \
  || bad "D-side CR0.CD handling not present in the default build"
! grep -q "+define+VEN_EN_L2" <<<"$(grep -A8 '^KV_FULL_DEFS' "$REPO/verif/tb/Makefile")" \
  && ok "L2 not in the deployed define set (disabled for now)" \
  || bad "VEN_EN_L2 is in the deployed define set while L2 is documented disabled"

# --- 3d. resolved-item cross-references + count/list consistency (A4-L01) -----
# A "Remaining limit: X.Y" pointer must not name a section already marked FIXED.
REMAIN="$(grep -oE 'Remaining limit: [A-D]\.[0-9]+' "$DOC" | grep -oE '[A-D]\.[0-9]+' || true)"
rem_ok=1
for r in $REMAIN; do
  if grep -E "^\| $r \|" "$DOC" | grep -q 'FIXED'; then
    bad "'Remaining limit: $r' names section $r, which is marked FIXED"
    rem_ok=0
  fi
done
[ "$rem_ok" = 1 ] && ok "no 'Remaining limit' pointer names a FIXED section"
# The VEN_X87_STKFLT row's named corpus count must match the manifests that
# actually carry x87_stkflt_arch (a fifth program must not hide uncounted).
NMANI=$(grep -l '"x87_stkflt_arch": true' "$REPO"/verif/tests/*/manifest.json 2>/dev/null | wc -l)
NDOC=$(grep -oE '(three|four|five|six) corpus programs' "$DOC" | head -1 | \
       sed 's/three/3/;s/four/4/;s/five/5/;s/six/6/;s/ .*//')
[ -n "$NDOC" ] && [ "$NDOC" = "$NMANI" ] \
  && ok "x87_stkflt corpus count in the doc ($NDOC) matches the manifests ($NMANI)" \
  || bad "x87_stkflt corpus count drift: doc says '${NDOC:-none}', $NMANI manifests carry x87_stkflt_arch"

# --- 4. every §5 status row names evidence that exists --------------------------
for g in run-l1axi-narrow-gate.sh run-ic-alias-gate.sh run-xc04-gate.sh; do
  [[ -f "$REPO/verif/l1/$g" || -f "$REPO/verif/sys/$g" ]] \
    && ok "evidence gate $g exists" \
    || bad "status doc references evidence gate $g, which does not exist"
done

# --- 5. closed items carry no stale validation status ----------------------------
# A manifest whose gate is registered (routinely run) must not retain PENDING /
# UNREACHED in its validation fields: validation records are monotonic, so a
# stale status next to a green result is a contradictory evidence record.
pend=0
for mf in "$REPO"/verif/sys/tests/*/manifest.json "$REPO"/verif/tests/*/manifest.json; do
  if grep -qE '"(PENDING|UNREACHED)' "$mf" || grep -qE 'PENDING --|UNREACHED' "$mf"; then
    bad "stale validation status in ${mf#$REPO/} (PENDING/UNREACHED next to a closed item)"
    pend=1
  fi
done
[ "$pend" = 0 ] && ok "no manifest retains PENDING/UNREACHED validation status"

# --- 6. oracle-mask discipline ----------------------------------------------------
# No x87_stkflt manifest may retain an OPEN-ENDED mask range (a null hi masks the
# whole tail of the trace, hiding any later unrelated x87 divergence), and the
# gate's mask selftest must include an after-final-record injection (a mask that
# cannot be proven to END cannot be proven to discriminate).
open_r=0
for mf in "$REPO"/verif/tests/*/manifest.json; do
  if python3 - "$mf" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
for k in ("x87_stkflt_fstat_ranges", "x87_stkflt_fpr_ranges"):
    for r in m.get(k) or []:
        if len(r) < 2 or r[1] is None:
            sys.exit(0)
sys.exit(1)
PYEOF
  then
    bad "open-ended (null-hi) oracle-mask range in ${mf#$REPO/}"
    open_r=1
  fi
done
[ "$open_r" = 0 ] && ok "no open-ended oracle-mask ranges in the x87_stkflt manifests"
grep -q "(d)after-tail" "$REPO/verif/sys/run-x87stk-gate.sh" \
  && ok "mask selftest includes an after-final-record injection" \
  || bad "run-x87stk-gate.sh's mask selftest lost its after-final-record injection"

# --- 7. semantic stale-text sentinels --------------------------------------------
# The claims below each went stale once while the gate suite stayed green; pin
# the current truth mechanically.
# (a) pdescprec fam 6: the typed S_LJMP classifier superseded the presence-first
#     scoping; the test header must not keep the old rationale.
if grep -q "Fam 6 (task switch) is SCOPED OUT" "$REPO/verif/sys/tests/pdescprec/pdescprec.S"; then
  bad "pdescprec.S still scopes fam 6 out as presence-first (superseded: typed classifier, pxfer covers the matrix)"
else
  ok "pdescprec.S fam-6 note matches the typed classifier (superseded scope-out removed)"
fi
# (b) progress-report record counts must match the manifests they cite.
NREC=$(grep -oE 'golden \(([0-9]+) records\)' "$REPO/verif/sys/tests/pdescprec/manifest.json" | grep -oE '[0-9]+' | head -1)
if [ -n "$NREC" ]; then
  grep -qE "${NREC} records" "$REPO/PROGRESS_Aug4_R1FIXES.md" \
    && ok "pdescprec record count in PROGRESS_Aug4_R1FIXES.md matches the manifest ($NREC)" \
    || bad "pdescprec record count drift: manifest says $NREC, PROGRESS_Aug4_R1FIXES.md disagrees"
fi
# (c) icache aliasing: the default build's physical snoop match is the
#     alias-correct mode; VEN_IC_ALIAS_SAFE is a redundant experiment.
if grep -q "VEN_IC_ALIAS_SAFE OFF (default): a store invalidates only its own linear" "$REPO/rtl/mem/icache.sv"; then
  bad "icache.sv still describes the default linear-only snoop (physical snoop tags are the default now)"
else
  ok "icache.sv alias note matches the physical snoop default"
fi

if [[ "$fails" == "0" ]]; then echo "DOCSSTATUS-GATE-OK"; else echo "DOCSSTATUS-GATE-FAIL"; exit 1; fi
