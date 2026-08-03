#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_aug2 C-06 (first bullet): a protected far CALL must not modify the stack
# before the destination is validated. BOTH halves are covered here:
#
#   pcallsel   an OUT-OF-TABLE selector -- rejected at dispatch and at both indirect
#              load completions, before S_LCALL runs at all.
#   pcalldesc  a selector that is fine but whose DESCRIPTOR has P=0 -- only reading the
#              descriptor can reject it, so this exercises the validate-then-push
#              reorder (SYS_LCALL -> S_LJMP probe -> S_LCALL push -> commit).
#
# Each witness is the ESP DELTA across the fault, so a wrong answer says how far off it
# was rather than merely failing. Both verified to FAIL (delta 8) against pre-fix builds.
#
# H-07's selector check runs at S_LCALL -> S_LJMP, which stops the out-of-table
# descriptor READ but runs AFTER both pushes. The check now also runs at dispatch, where
# the selector is already known and nothing has touched the stack.
#
# The witness carries the ESP DIFFERENCE across the fault, so a wrong answer says how
# far off it was:
#   ebp = 0x0CA10000   stack untouched -- rejected before any push          PASS
#   ebp = 0x0CA10008   CS and next_eip were pushed before the rejection     FAIL
#   ebp = 0xBADBAD00   the far CALL SUCCEEDED with an out-of-table selector FAIL
#
# THIS DOES NOT CLOSE C-06. The DESCRIPTOR checks (present, code, DPL, conforming) still
# need the read S_LJMP performs after the push; unwinding those needs the far-transfer
# staging the finding asks for. This covers the selector class only -- the one decidable
# without a memory access.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TB="$REPO/verif/tb/${OBJDIR:-obj_dir}/tb_ventium"
IMG="$REPO/verif/sys/tests/pcallsel/pcallsel.bin"

echo "== REVIEW2_aug2 C-06: far CALL must not push before validating the selector =="
[[ -x "$TB"  ]] || { echo "  SKIP: $TB missing"; exit 0; }
[[ -f "$IMG" ]] || { echo "  SKIP: pcallsel.bin missing"; exit 0; }

fails=0
chk() {  # $1 image, $2 expected ebp, $3 label, $4 wrong-value hint
  local img="$REPO/verif/sys/tests/$1/$1.bin" tr out
  [[ -f "$img" ]] || { echo "  SKIP: $1.bin missing"; return 0; }
  tr="$(mktemp)"
  "$TB" --image "$img" --system --out "$tr" --max-insn 6000 --quiesce 600 >/dev/null 2>&1 || true
  out="$(tail -1 "$tr" 2>/dev/null | grep -o '"ebp":"[^"]*"' | cut -d'"' -f4 || true)"
  rm -f "$tr"
  echo "  $3: ebp = ${out:-<none>}   (want $2)"
  if [[ "$out" == "$2" ]]; then echo "    ok   the stack was untouched"; return 0; fi
  [[ "$out" == "$4" ]] && echo "    FAIL ESP was 8 lower at the fault -- CS:next_eip were pushed BEFORE the"
  [[ "$out" == "$4" ]] && echo "         target was rejected. That is C-06."
  [[ "$out" != "$4" ]] && echo "    FAIL unexpected witness; the test did not reach its fault as designed."
  return 1
}

chk pcallsel  0x0ca10000 "SELECTOR   out-of-table (rejected at dispatch)" 0x0ca10008 || fails=1
chk pcalldesc 0x0b000000 "DESCRIPTOR not-present (rejected in the probe)" 0x0b000008 || fails=1

if [[ "$fails" == "0" ]]; then
  echo "CALLSEL-GATE-OK"; exit 0
fi
echo "CALLSEL-GATE-FAIL"; exit 1
