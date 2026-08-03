#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_aug2 C-03 (fourth bullet): an IDT gate offset beyond the destination CS
# limit must be rejected DURING delivery, before CS/CPL are installed.
#
# The assertion is the SAVED CS on the #GP frame, which names where the fault was
# taken. Both a fixed and a broken core take a #GP here -- that is exactly why the
# first draft of pintlim passed with the fix reverted -- so "a #GP happened" is not
# the check and must never become it:
#
#   ebp = 0x0C030008   delivery rejected the gate; CS was never installed   PASS
#   ebp = 0x0C030018   CS 0x18 WAS installed and the overrun fetch faulted  FAIL
#   ebp = 0x00000000   no fault at all; delivery accepted an out-of-limit offset
#
# esi carries the saved EIP and is reported for corroboration: it is the `int $0x40`
# instruction when delivery rejects, and an address inside the image when it does not.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="${OBJDIR:-obj_dir}"
TB="$REPO/verif/tb/$OBJ/tb_ventium"
IMG="$REPO/verif/sys/tests/pintlim/pintlim.bin"

echo "== REVIEW2_aug2 C-03: IDT gate offset vs destination CS limit =="

[[ -x "$TB"  ]] || { echo "  SKIP: $TB missing (build it first)"; exit 0; }
[[ -f "$IMG" ]] || { echo "  SKIP: pintlim.bin missing (make -C verif/sys/tests/pintlim)"; exit 0; }

TR="$(mktemp)"; trap 'rm -f "$TR"' EXIT
"$TB" --image "$IMG" --system --out "$TR" --max-insn 3000 --quiesce 400 >/dev/null 2>&1 || true

LAST="$(tail -1 "$TR" 2>/dev/null || true)"
EBP="$(printf '%s' "$LAST" | grep -o '"ebp":"[^"]*"' | cut -d'"' -f4 || true)"
ESI="$(printf '%s' "$LAST" | grep -o '"esi":"[^"]*"' | cut -d'"' -f4 || true)"

echo "  saved CS witness ebp = ${EBP:-<none>}   saved EIP esi = ${ESI:-<none>}"

case "$EBP" in
  0x0c030008)
    echo "  ok   the gate was rejected during DELIVERY (saved CS 0x08 -- CS never installed)"
    echo "INTLIM-GATE-OK"
    exit 0 ;;
  0x0c030018)
    echo "  FAIL CS 0x18 was INSTALLED before the offset was checked: the #GP came from"
    echo "       the handler's own overrun fetch, not from delivery. That is C-03."
    echo "INTLIM-GATE-FAIL"
    exit 1 ;;
  0x00000000)
    echo "  FAIL no fault at all -- delivery accepted an out-of-limit handler offset."
    echo "INTLIM-GATE-FAIL"
    exit 1 ;;
  *)
    echo "  FAIL unexpected witness. The test did not reach its exit as designed;"
    echo "       an absent or malformed witness is a gate failure, not a pass."
    echo "INTLIM-GATE-FAIL"
    exit 1 ;;
esac
