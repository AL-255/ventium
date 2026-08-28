#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW1_Aug3 R2-C03: page-crossing FRAGMENT ENGINE correctness gate.
#
# This used to be a REACHABILITY PIN: it PASSED only while each of the six
# non-split producers $fatal'd ("PAGING/C-04 UNSPLIT page-crossing") on a
# directed crossing access. The generic fragment engine (rtl/core/core.sv fx_*)
# now gives every translatable FSM state a probe-then-execute fragment
# sequence, so the fatal correctly NEVER fires -- and this gate is converted
# into the completion-form CORRECTNESS regression, per the finding's delivery
# note ("when the fragment engine lands, this pin must be replaced by the
# completion-form regression in the same commit").
#
# For each of the six producer images (verif/sys/tests/pxc04*/, all built on the
# pfault skeleton, all with the crossing window on NON-CONTIGUOUS physical
# frames so a wrong-physical-page access returns poison):
#
#   pxc04  S_LGDT      6-byte pseudo-descriptor read at 0x2FFE (limit page 2,
#                      base page 3 = phys 0x600000). Case A: NP page 3 -> #PF
#                      (CR2=0x3000) with GDTR PROVABLY unchanged; case B: the
#                      restarted LGDT's GDTR is exercised by real segment loads.
#   pxc04i S_INT_PUSH  UD2 at ESP=0x8E002: the 12-byte frame straddles 0x8E000
#                      (page 0x8E = phys 0x700000); the handler verifies saved
#                      EIP/CS from both pages. (No NP variant: the push IS
#                      delivery, so a rejecting page faults the delivery
#                      recursively into a triple fault on ANY correct CPU.)
#   pxc04f S_FSTORE    FSTP m64 at 0x2FFE. Case A: NP page 3 -> #PF BEFORE any
#                      commit (page-1 sentinel untouched); case B: the restarted
#                      store lands split across phys 0x2FFE / phys 0x600002.
#   pxc04e S_FENV_ST   FNSTENV at 0x2FFE: same atomicity case + CW/SW/TW field
#                      readback across the split.
#   pxc04t S_TSW_SAVE  Outgoing TSS based at 0x2FDE so the saved-EIP dword
#                      straddles onto phys 0x600000; the incoming task verifies
#                      the saved fields. (No NP variant: QEMU's dummy TSS
#                      pre-access faults at a different address than the RTL's
#                      probe -- an oracle gap on CR2, see the manifest.)
#   pxc04m S_INT_GATE  Misaligned IDT (base 0x4FCE) puts vector 6's gate at
#                      0x4FFE (page 5 = phys 0x601000): UD2 must reach the real
#                      handler; then page 5 NP + int $32 -> #PF(CR2=0x5000)
#                      before any delivery commits, then completion.
#
# Gate semantics per producer: run verif/sys/run-sys-golden.sh (QEMU golden +
# witness validation + RTL --system diff). PASS requires SYS-GOLDEN-OK AND no
# "PAGING/C-04" assertion anywhere in the RTL run's output.
#
# STATUS (2026-08-04): 6/6 producers GREEN. The pxc04 (S_LGDT read-path) defect
# this gate used to pin -- a read frag2's D-TLB miss diverted to S_WALK with
# the engine's read-merge still armed, so the walk's PDE latch sampled
# fx_merged (measured: walk_pde := (PDE<<16)|frag1[15:0]) -- is FIXED: the
# engine sequencer now freezes and every shaping output blanks while
# state==S_WALK (fx_walk_hold, rtl/core/core.sv), and the frag sequence resumes
# when the walk returns to the producer state. The pin half is deleted per its
# own instruction; xc04 moves to the PASS class in run-verify-all.sh and pxc04
# joins verify-sys + the seg-gate sweep in the same change.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TB="$REPO/verif/tb/${OBJDIR:-obj_dir}/tb_ventium"

echo "== REVIEW1_Aug3 R2-C03: page-crossing fragment engine CORRECTNESS =="
[[ -x "$TB"  ]] || { echo "  SKIP: $TB missing"; exit 0; }

fails=0
probe() {   # $1 = image basename, $2 = producer description
  local img="$REPO/verif/sys/tests/$1/$1.bin"
  if [[ ! -f "$img" ]]; then echo "  SKIP: $1.bin missing"; return 0; fi
  local out
  out="$(bash "$REPO/verif/sys/run-sys-golden.sh" "$1" 2>&1)"
  local rc=$?
  # The C-04 fatal must NEVER appear, in any run, green or red.
  if printf '%s\n' "$out" | grep -q 'PAGING/C-04: UNSPLIT'; then
    echo "  FAIL $1 ($2): the PAGING/C-04 UNSPLIT fatal fired -- the fragment"
    echo "       engine regressed to the unsplit path for this producer."
    fails=1; return 1
  fi
  if [[ "$rc" == "0" ]] && printf '%s\n' "$out" | grep -q 'SYS-GOLDEN-OK'; then
    echo "  ok   $1 ($2): crossing completes, differential EQUIVALENT"
    return 0
  fi
  echo "  FAIL $1 ($2): the crossing does NOT complete correctly -- the RTL"
  echo "       diverges from the QEMU golden (run: bash verif/sys/run-sys-golden.sh $1)."
  printf '%s\n' "$out" | grep -E 'divergence|LENGTH MISMATCH|FATAL' | head -3 | sed 's/^/       /'
  fails=1; return 1
}

probe pxc04  "S_LGDT      descriptor-table read"    || true
probe pxc04i "S_INT_PUSH  exception frame write"  || true
probe pxc04f "S_FSTORE    x87 FSTP m64 beat"       || true
probe pxc04e "S_FENV_ST   FNSTENV image beat"      || true
probe pxc04t "S_TSW_SAVE  task-switch state save"  || true
probe pxc04m "S_INT_GATE  IDT gate read (microseq)" || true

if [[ "$fails" == "0" ]]; then
  echo "  => all six producers' crossings complete differentially clean (S_LGDT,"
  echo "     S_INT_PUSH, S_FSTORE, S_FENV_ST, S_TSW_SAVE, S_INT_GATE), incl. the"
  echo "     read-frag2 page walk that the deleted pin used to hold."
  echo "XC04-GATE-OK"; exit 0
fi
echo "XC04-GATE-FAIL"; exit 1
