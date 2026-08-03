#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_aug2 H-07: a far RETF must bound its POPPED CS selector against the
# descriptor table before issuing the descriptor read.
#
# pretfsel far-returns to selector 0x0F00 against a three-entry GDT. Measured:
#
#   ebp = 0x0D000F00   #GP(0x0F00) delivered -- rejected before the read     PASS
#   ebp = 0x0B000F00   #NP instead: the out-of-table read HAPPENED and the
#                      descriptor it found decided the exception             FAIL
#   ebp = 0xBADBAD00   the RETF SUCCEEDED with an out-of-table selector      FAIL
#   (absent / 0)       the pre-fix behaviour: no fault at all, the core stalls
#                      AT the LRET (1105 retired vs 1113)                    FAIL
#
# The last row is why an absent witness must fail rather than read as "not
# applicable" -- it is precisely the broken build's signature.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="${OBJDIR:-obj_dir}"
TB="$REPO/verif/tb/$OBJ/tb_ventium"
IMG="$REPO/verif/sys/tests/pretfsel/pretfsel.bin"

echo "== REVIEW2_aug2 H-07: far RETF must bound its popped CS selector =="

[[ -x "$TB"  ]] || { echo "  SKIP: $TB missing (build it first)"; exit 0; }
[[ -f "$IMG" ]] || { echo "  SKIP: pretfsel.bin missing (make -C verif/sys/tests/pretfsel)"; exit 0; }

TR="$(mktemp)"; trap 'rm -f "$TR"' EXIT
"$TB" --image "$IMG" --system --out "$TR" --max-insn 6000 --quiesce 400 >/dev/null 2>&1 || true

EBP="$(tail -1 "$TR" 2>/dev/null | grep -o '"ebp":"[^"]*"' | cut -d'"' -f4 || true)"
N="$(wc -l < "$TR" 2>/dev/null || echo 0)"
echo "  witness ebp = ${EBP:-<none>}   (retired records: $N)"

case "$EBP" in
  0x0d000f00)
    echo "  ok   #GP(0x0F00): the selector was rejected BEFORE the descriptor read"
    echo "RETFSEL-GATE-OK"; exit 0 ;;
  0x0b000f00)
    echo "  FAIL #NP was delivered, so the out-of-table descriptor read HAPPENED and"
    echo "       the bytes it landed on chose the exception. That is H-07."
    echo "RETFSEL-GATE-FAIL"; exit 1 ;;
  0xbadbad00)
    echo "  FAIL the far RETF SUCCEEDED with a selector past the GDT limit."
    echo "RETFSEL-GATE-FAIL"; exit 1 ;;
  *)
    echo "  FAIL no #GP witness. The pre-fix core raises NO fault here and stalls at"
    echo "       the LRET, which is exactly this outcome -- so an absent witness is a"
    echo "       failure, not an inconclusive run."
    echo "RETFSEL-GATE-FAIL"; exit 1 ;;
esac
