#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_aug2 C-06 (first bullet, selector half): a protected far CALL must not modify
# the stack before the destination is validated.
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

TR="$(mktemp)"; trap 'rm -f "$TR"' EXIT
"$TB" --image "$IMG" --system --out "$TR" --max-insn 6000 --quiesce 600 >/dev/null 2>&1 || true
EBP="$(tail -1 "$TR" 2>/dev/null | grep -o '"ebp":"[^"]*"' | cut -d'"' -f4 || true)"
echo "  ESP-delta witness ebp = ${EBP:-<none>}   (want 0x0ca10000)"

case "$EBP" in
  0x0ca10000) echo "  ok   the stack was untouched: rejected before any push"
              echo "CALLSEL-GATE-OK"; exit 0 ;;
  0x0ca10008) echo "  FAIL ESP was 8 lower at the fault -- CS and next_eip were pushed"
              echo "       before the selector was rejected. That is C-06."
              echo "CALLSEL-GATE-FAIL"; exit 1 ;;
  0xbadbad00) echo "  FAIL the far CALL SUCCEEDED with a selector past the GDT limit."
              echo "CALLSEL-GATE-FAIL"; exit 1 ;;
  *)          echo "  FAIL no usable witness; the test did not reach its fault."
              echo "CALLSEL-GATE-FAIL"; exit 1 ;;
esac
