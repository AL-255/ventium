#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_aug2 C-06 (call-gate half): a far CALL through a call gate to a MORE
# privileged code segment must SWITCH STACKS -- SS:ESP from TSS.ssN/espN, then the
# caller's SS:ESP and the return CS:EIP pushed on the NEW stack.
#
# TWO defects are covered here, and the second was found only because the first was
# fixed:
#
#   1. THE GATE DPL WAS READ FROM THE WRONG BITS. The arm used desc[45:44] where the
#      access byte's DPL is desc[46:45]; for a system descriptor (S=0) that decodes a
#      DPL-3 gate as DPL 2. `gdpl < cpl_r` then rejected EVERY DPL-3 gate called from
#      ring 3 with #GP(selector) -- and a DPL-3 gate is the only kind ring-3 code can
#      use. No cross-privilege call gate could be taken at all.
#   2. The cross-privilege stack switch itself was not implemented (it halted at tag
#      0xDB). That halt was UNREACHABLE in every corpus run because defect 1 killed
#      the transfer one check earlier -- which is exactly why "0 observed" was not
#      evidence of anything.
#
# THE WITNESS IS THE RING-0 SS AND THE RECOVERED CALLER ESP, not "did we reach CPL 0":
#
#   fixed   ebp=0x0CA60010  esi=0x00005000  (ss=TSS.SS0, caller ESP read from frame)
#   before  ebp=0x00000000  esi=0x00000000  (spurious #GP at the lcall; ring 0 never
#                                            reached, so the witness stays 0)
#
# esp is checked too: TSS.ESP0 is 0x6000 and the gate frame is 4 dwords, so a correct
# switch lands the callee at 0x5FF0. That distinguishes "SS was loaded" from "SS was
# loaded AND the frame was actually pushed on it".
#
# PARAM COUNT > 0 remains unimplemented and halts loudly with its own tag (0xDA).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TB="$REPO/verif/tb/obj_dir/tb_ventium"
IMG="$REPO/verif/sys/tests/pcallxpl/pcallxpl.bin"

echo "== REVIEW2_aug2 C-06: cross-privilege call gate (stack switch) =="
[[ -x "$TB"  ]] || { echo "  SKIP: tb missing (make -C verif/tb rtl)"; exit 0; }
[[ -f "$IMG" ]] || { echo "  SKIP: pcallxpl.bin missing"; exit 0; }

tr_out="$(mktemp)"
"$TB" --image "$IMG" --system --out "$tr_out" --max-insn 4000 --quiesce 400 >/dev/null 2>&1 || true
last="$(tail -1 "$tr_out" 2>/dev/null || true)"
rm -f "$tr_out"

g(){ printf '%s' "$last" | grep -o "\"$1\":\"[^\"]*\"" | cut -d'"' -f4 || true; }
ebp="$(g ebp)"; esi="$(g esi)"; ss="$(g ss)"; cs="$(g cs)"; esp="$(g esp)"
echo "  callee: cs=${cs:-<none>} ss=${ss:-<none>} esp=${esp:-<none>} ebp=${ebp:-<none>} esi=${esi:-<none>}"

if [[ "$ebp" == "0x00000000" ]]; then
  echo "  FAIL ring 0 was never reached -- the gate was rejected (historically a"
  echo "       spurious #GP from the desc[45:44] DPL misread) or it halted."
  echo "CALLXPL-GATE-FAIL"; exit 1
fi
if [[ "$ebp" != "0x0ca60010" ]]; then
  echo "  FAIL callee is NOT on the TSS stack: expected ss=0x10, witness 0x0ca60010."
  echo "       A callee at CPL 0 holding the CALLER's stack is the escalation this"
  echo "       finding is about."
  echo "CALLXPL-GATE-FAIL"; exit 1
fi
if [[ "$esi" != "0x00005000" ]]; then
  echo "  FAIL the caller's ESP was not pushed: frame slot reads $esi, want 0x00005000."
  echo "CALLXPL-GATE-FAIL"; exit 1
fi
if [[ "$esp" != "0x00005ff0" ]]; then
  echo "  FAIL SS switched but the frame is not on it: esp=$esp, want 0x00005ff0"
  echo "       (TSS.ESP0 0x6000 minus the 4-dword gate frame)."
  echo "CALLXPL-GATE-FAIL"; exit 1
fi
echo "  ok   stack switched from the TSS, caller SS:ESP pushed, frame on the new stack"
echo "CALLXPL-GATE-OK"; exit 0
