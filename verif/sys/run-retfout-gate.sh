#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_aug2 C-06: a far RETF to an OUTER privilege level must POP AND VALIDATE
# SS:ESP and switch to the outer stack.
#
# The core reused far-JMP semantics for RETF: it loaded CS and took CPL from the
# popped RPL but never touched SS:ESP. Ring-3 code therefore ran holding the RING-0
# stack pointer -- a privilege-escalation primitive, and one that failed silently.
#
# THE WITNESS IS SS, NOT THE PRIVILEGE LEVEL, and that distinction is the whole test.
# Both builds reach ring 3 (CPL takes the popped RPL either way), so "did we get to
# CPL 3" passes against the bug. What differs is which stack ring 3 is standing on:
#
#   fixed     ebp=0x0C060023  esi=0x00008000  (ss=0x23 ring-3 stack, esp from frame)
#   broken    ebp=0x0C060010  esi=0x00006FF8  (ss=0x10 RING-0 stack, inner esp)
#
# SEEN TO FAIL: measured against the pre-fix build at commit cc9d1b4, same image.
# That is a real reversion measurement, not a prediction -- pintlim's first draft
# passed with its fix reverted, and this gate is shaped to not repeat it.
#
# The run ends "quiescent (core idle)": the final OUT to 0xF4 never acks outside
# cosim, so the core stalls on it and the witness lands in the last RETIRED record.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TB="$REPO/verif/tb/obj_dir/tb_ventium"
IMG="$REPO/verif/sys/tests/pretfout/pretfout.bin"

echo "== REVIEW2_aug2 C-06: far RETF to an outer privilege level =="
[[ -x "$TB"  ]] || { echo "  SKIP: tb missing (make -C verif/tb rtl)"; exit 0; }
[[ -f "$IMG" ]] || { echo "  SKIP: pretfout.bin missing (make -C verif/sys/tests/pretfout)"; exit 0; }

tr_out="$(mktemp)"
"$TB" --image "$IMG" --system --out "$tr_out" --max-insn 4000 --quiesce 400 >/dev/null 2>&1 || true
last="$(tail -1 "$tr_out" 2>/dev/null || true)"
rm -f "$tr_out"

ebp="$(printf '%s' "$last" | grep -o '"ebp":"[^"]*"' | cut -d'"' -f4 || true)"
esi="$(printf '%s' "$last" | grep -o '"esi":"[^"]*"' | cut -d'"' -f4 || true)"
ss="$(printf  '%s' "$last" | grep -o '"ss":"[^"]*"'  | cut -d'"' -f4 || true)"
cs="$(printf  '%s' "$last" | grep -o '"cs":"[^"]*"'  | cut -d'"' -f4 || true)"

echo "  ring-3 tail: cs=${cs:-<none>} ss=${ss:-<none>} ebp=${ebp:-<none>} esi=${esi:-<none>}"

if [[ "$cs" != "0x001b" ]]; then
  echo "  FAIL the RETF did not transfer to ring 3 at all (cs != 0x001b), so this"
  echo "       says nothing about the stack. Check the image, not the RETF path."
  echo "RETFOUT-GATE-FAIL"; exit 1
fi
if [[ "$ebp" == "0x0c060010" ]]; then
  echo "  FAIL ring-3 code is running on the RING-0 stack (ss=0x10). SS:ESP were not"
  echo "       popped or validated -- REVIEW2_aug2 C-06, the escalation primitive."
  echo "RETFOUT-GATE-FAIL"; exit 1
fi
if [[ "$ebp" != "0x0c060023" ]]; then
  echo "  FAIL neither expected witness; the test did not run as designed."
  echo "RETFOUT-GATE-FAIL"; exit 1
fi
if [[ "$esi" != "0x00008000" ]]; then
  echo "  FAIL SS was switched but ESP was not: esi=$esi, want 0x00008000. The segment"
  echo "       half alone looks right while the pointer still addresses the inner stack."
  echo "RETFOUT-GATE-FAIL"; exit 1
fi
echo "  ok   outer SS AND ESP both came from the frame and were validated before commit"
echo "RETFOUT-GATE-OK"; exit 0
