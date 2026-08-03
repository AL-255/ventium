#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_aug2 C-03 (fifth bullet + the CPL half of the first): a cross-privilege
# delivery must bound the TSS.ssN:espN read against tr_limit and raise #TS -- and that
# #TS must be classified at the ORIGINAL privilege, not at the target's.
#
# ptsslim populates the TSS memory correctly and truncates only the DESCRIPTOR limit
# to 0x0007, which stops short of SS0 at offset 8..11. Both a fixed and a broken core
# run to completion; the witness says which path was taken:
#
#   ebp = 0x75510028   #TS(0x28) raised BEFORE the read and delivered to the DPL3
#                      conforming handler at CPL3                            PASS
#   ebp = 0x0BAD0040   the read ran past the limit, found the good SS0/ESP0 sitting
#                      there, and delivery SUCCEEDED into the CPL0 handler   FAIL
#   ebp = 0x00000000   INT 0x40 returned; neither expected path was taken    FAIL
#   (no witness)       the delivery stalled or escalated                     FAIL
#
# That last case is not hypothetical. Before the CPL half was staged, cpl_r had
# already been lowered to the target's DPL by the time the #TS was raised, so the
# DPL3 conforming handler failed its own tgt_dpl > eff_cpl test and the fault chain
# went #TS -> #GP(0x32) -> #NP(0x42) -> shutdown, reporting nothing at all. An absent
# witness must therefore FAIL rather than be mistaken for "did not apply".
#
# cs/ss are printed for corroboration: the handler must run with CS = the conforming
# selector 0x30 and SS still the CPL3 stack 0x23 (a conforming target performs NO
# stack switch, which is the only reason a broken TSS can be reported at all).

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="${OBJDIR:-obj_dir}"
TB="$REPO/verif/tb/$OBJ/tb_ventium"
IMG="$REPO/verif/sys/tests/ptsslim/ptsslim.bin"

echo "== REVIEW2_aug2 C-03: truncated TSS must #TS, classified at the OLD CPL =="

[[ -x "$TB"  ]] || { echo "  SKIP: $TB missing (build it first)"; exit 0; }
[[ -f "$IMG" ]] || { echo "  SKIP: ptsslim.bin missing (make -C verif/sys/tests/ptsslim)"; exit 0; }

TR="$(mktemp)"; trap 'rm -f "$TR"' EXIT
"$TB" --image "$IMG" --system --out "$TR" --max-insn 6000 --quiesce 400 >/dev/null 2>&1 || true

LAST="$(tail -1 "$TR" 2>/dev/null || true)"
EBP="$(printf '%s' "$LAST" | grep -o '"ebp":"[^"]*"' | cut -d'"' -f4 || true)"
ESI="$(printf '%s' "$LAST" | grep -o '"esi":"[^"]*"' | cut -d'"' -f4 || true)"
EDI="$(printf '%s' "$LAST" | grep -o '"edi":"[^"]*"' | cut -d'"' -f4 || true)"
CS="$( printf '%s' "$LAST" | grep -o '"cs":"[^"]*"'  | cut -d'"' -f4 || true)"
SS="$( printf '%s' "$LAST" | grep -o '"ss":"[^"]*"'  | cut -d'"' -f4 || true)"

echo "  witness ebp = ${EBP:-<none>}  saved EIP esi = ${ESI:-<none>}  cs = ${CS:-?} ss = ${SS:-?}"
echo "  saved CS on the #TS frame edi = ${EDI:-<none>}  (must be 0x1b = the interrupted CS)"

case "$EBP" in
  0x75510028)
    if [[ "$CS" != "0x0030" || "$SS" != "0x0023" ]]; then
      echo "  FAIL the #TS was reported, but not from where it must be: expected the"
      echo "       conforming handler cs=0x0030 on the UNSWITCHED CPL3 stack ss=0x0023."
      echo "TSSLIM-GATE-FAIL"; exit 1
    fi
    if [[ "$EDI" != "0x0000001b" ]]; then
      echo "  FAIL the #TS frame saved CS=$EDI. This fault is raised LATE in the INT 0x40"
      echo "       delivery, so a saved CS of 0x08 means the handler's CS was installed"
      echo "       before the delivery was known to succeed and the frame reports a"
      echo "       selector the interrupted code never ran in. That is C-03's first"
      echo "       bullet (stage the control context to one commit point)."
      echo "TSSLIM-GATE-FAIL"; exit 1
    fi
    echo "  ok   #TS(0x28) raised before the read, delivered at CPL3 with no stack switch"
    echo "  ok   the #TS frame reports the INTERRUPTED CS (0x1b), not the handler's"
    echo "TSSLIM-GATE-OK"; exit 0 ;;
  0x0bad0040)
    echo "  FAIL the ssN:espN read ran PAST tr_limit and delivery succeeded on values"
    echo "       taken from beyond the TSS. That is C-03's fifth bullet."
    echo "TSSLIM-GATE-FAIL"; exit 1 ;;
  0x00000000)
    echo "  FAIL INT 0x40 returned to CPL3 -- neither expected path was taken."
    echo "TSSLIM-GATE-FAIL"; exit 1 ;;
  *)
    echo "  FAIL no usable witness: the delivery stalled or escalated instead of"
    echo "       reporting. See the header -- this is the CPL-staging failure mode."
    echo "TSSLIM-GATE-FAIL"; exit 1 ;;
esac
