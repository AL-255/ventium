#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_Aug1 C-06 gate — per-access SEGMENT LIMIT enforcement.
#
# WHY THIS IS A SELF-CHECK AND NOT A DIFFERENTIAL TEST
# ----------------------------------------------------
# QEMU does not enforce segment limits. Measured directly, with every intermediate
# layer removed (the test encodes its #GP counter into the isa-debug-exit status, so
# no gdbstub / gen_trace / QMP / trace parsing is involved):
#
#     qemu-system-i386 -bios pseglim.bin  ->  exit 133   (#GP counter == 0, NO fault)
#                                             exit 135 would mean the #GP fired
#
# So a CORRECT Ventium diverges from the golden here and a diff would fail precisely
# when the core is right. This gate therefore checks Ventium against the SDM directly.
#
# WHAT IT ASSERTS
#   1. POSITIVE: pseglim's out-of-limit access raises exactly ONE #GP(0), at the
#      faulting instruction, and the program then RUNS TO COMPLETION (ecx == 1).
#   2. NEGATIVE: across every system test, the check rejects NOTHING. This is the
#      false-positive tripwire, and it is the assertion that matters -- C-06's
#      delivery was reverted twice for shipping false positives, so "it fires on the
#      violation" is worth little without "it fires on nothing else".
#
# Enforcement is NOT compiled into the default build (see core_fetch_decode.svh for
# why), so this gate builds its own object directory with +define+VEN_SEG_ENFORCE.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
OBJ=obj_dir_seg
TB="$REPO/verif/tb/$OBJ/tb_ventium"

echo "=== 1. build the RTL with +define+VEN_SEG_ENFORCE (separate objdir) ==="
make -s -C verif/tb rtl OBJDIR="$OBJ" VL_EXTRA_DEFINES="+define+VEN_SEG_ENFORCE" >/dev/null
[[ -x "$TB" ]] || { echo "FATAL: enforcement TB not built at $TB"; exit 1; }
echo "  built: $TB"

echo
echo "=== 2. build pseglim ==="
make -s -C verif/sys/tests/pseglim >/dev/null 2>&1
IMG="$REPO/verif/sys/tests/pseglim/pseglim.bin"
[[ -f "$IMG" ]] || { echo "FATAL: pseglim.bin missing"; exit 1; }
echo "  image: $IMG"

echo
echo "=== 3. POSITIVE: the out-of-limit access must raise exactly one #GP(0) ==="
OUT="$REPO/build/sys/pseglim.seg.vtrace"
mkdir -p "$REPO/build/sys"
LOG="$("$TB" --image "$IMG" --system --out "$OUT" --max-insn 900 --quiesce 400 \
        +ven_faultlog 2>&1 || true)"
NGP="$(printf '%s\n' "$LOG" | grep -c 'vec=13 ' || true)"
GPPC="$(printf '%s\n' "$LOG" | sed -n 's/.*vec=13 .*pc=\([0-9a-f]*\).*/\1/p' | head -1)"
echo "  #GP(13) deliveries: $NGP   at pc=${GPPC:-<none>}"
if [[ "$NGP" != "1" ]]; then
  echo "FATAL: expected exactly ONE #GP; got $NGP."
  echo "       0 = the limit violation was not caught (enforcement inert)."
  echo "       >1 = the handler itself is faulting (a false positive, which is how"
  echo "            this finding's delivery got reverted the last two times)."
  printf '%s\n' "$LOG" | grep FAULT | head -6
  exit 1
fi

# ecx is the #GP counter the handler increments; PROGRESS_aug2.md set `ecx == 1` as
# the condition for re-admitting this test to the gates.
ECX="$(tail -1 "$OUT" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read())["ecx"])')"
echo "  final ecx (#GP counter) = $ECX  (want 0x00000001)"
if [[ "$ECX" != "0x00000001" ]]; then
  echo "FATAL: the #GP was delivered but the program did not complete normally."
  echo "       ecx=$ECX means the handler did not run to its increment, or ran twice."
  exit 1
fi
echo "  SEG-POSITIVE-OK: one #GP(0) at the violating access; handler ran; test completed"

echo
echo "=== 4. NEGATIVE: the check must reject NOTHING across the system corpus ==="
TESTS="pseg pmode ppage pxpage pintr pintr16 pfault pfcpl3 pde pcpl pssiret pstk16 pdf ptask ptaskcpl ptaskv86 pdebug ppopf pv86"
TOTAL=0; NRUN=0
for t in $TESTS; do
  TIMG="$REPO/verif/sys/tests/$t/$t.bin"
  [[ -f "$TIMG" ]] || continue
  NRUN=$((NRUN+1))
  N="$("$TB" --image "$TIMG" --system --out /dev/null --max-insn 1200 --quiesce 400 \
        +ven_seglog 2>&1 | grep -c SEGCHK || true)"
  TOTAL=$((TOTAL+N))
  if [[ "$N" != "0" ]]; then echo "  $t: $N would-be rejections"; fi
done
echo "  ran $NRUN system tests; total would-be rejections: $TOTAL (want 0)"
if [[ "$TOTAL" != "0" ]]; then
  echo "FATAL: the segment check would reject $TOTAL legitimate accesses."
  echo "       Every previous attempt at this finding shipped exactly this failure."
  echo "       Re-run one of the listed tests with +ven_seglog to see the basis."
  exit 1
fi
echo "  SEG-NEGATIVE-OK: zero false positives across $NRUN system tests"

echo
echo "SEG-GATE-OK  (C-06: per-access segment limits enforced; positive + negative)"
