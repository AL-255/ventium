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
#   1. POSITIVE: pseglim's out-of-limit LOAD and out-of-limit STORE each raise a
#      #GP(0), as does a WRITE THROUGH A READ-ONLY segment (ecx == 3), the program
#      runs to completion, AND both violating stores' target memory is UNTOUCHED --
#      the fault must suppress the access, not merely follow it (REVIEW1_Aug2 C-01).
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
echo "=== 3. POSITIVE: both violations must fault, and the store must not commit ==="
OUT="$REPO/build/sys/pseglim.seg.vtrace"
mkdir -p "$REPO/build/sys"
LOG="$("$TB" --image "$IMG" --system --out "$OUT" --max-insn 900 --quiesce 400 \
        +ven_faultlog 2>&1 || true)"
NGP="$(printf '%s\n' "$LOG" | grep -c 'vec=13 ' || true)"
GPPC="$(printf '%s\n' "$LOG" | sed -n 's/.*vec=13 .*pc=\([0-9a-f]*\).*/\1/p' | head -1)"
echo "  #GP(13) deliveries: $NGP   at pc=${GPPC:-<none>} (first)"
if [[ "$NGP" != "3" ]]; then
  echo "FATAL: expected exactly THREE #GP (limit-load, limit-STORE, read-only WRITE);"
  echo "       got $NGP."
  echo "       0 = the limit violation was not caught (enforcement inert)."
  echo "       <3 = one of the three forms is not checked (limit vs type)."
  echo "       >2 = the handler itself is faulting (a false positive, which is how"
  echo "            this finding's delivery got reverted the last two times)."
  printf '%s\n' "$LOG" | grep FAULT | head -8
  exit 1
fi

# REVIEW1_Aug2 C-01: a #GP must SUPPRESS the faulting access, not merely follow it.
# seg_access_fault was consumed by the FSM but absent from the bus driver's squash
# list, so a limit-violating STORE reached memory before the fault was delivered.
# ebp carries a witness seeded at the linear address that store targets; it must be
# untouched. Without the squash it reads 0xcafebabe (the store's data).
EBP="$(tail -1 "$OUT" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read())["ebp"])')"
echo "  witness at the violating store's target = $EBP  (want 0x5eedf00d)"
EDI="$(tail -1 "$OUT" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read())["edi"])')"
echo "  witness at the read-only write's target = $EDI  (want 0x1111aaaa)"
if [[ "$EDI" != "0x1111aaaa" ]]; then
  echo "FATAL: a write through a READ-ONLY data segment reached memory."
  echo "       0x2222bbbb means seg_type_fault did not fire or did not suppress."
  exit 1
fi
if [[ "$EBP" != "0x5eedf00d" ]]; then
  echo "FATAL: the limit-violating STORE reached memory before the #GP was delivered."
  echo "       0xcafebabe means the store committed; the access must be SQUASHED, not"
  echo "       merely followed by a fault. See core_bus_driver.svh (the squash must sit"
  echo "       OUTSIDE the paging block -- segment limits apply with paging off too)."
  exit 1
fi

# ecx is the #GP counter the handler increments. PROGRESS_aug2.md set `ecx == 1` as
# the condition for re-admitting this test; it is 2 now that C-01 added the store.
ECX="$(tail -1 "$OUT" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read())["ecx"])')"
echo "  final ecx (#GP counter) = $ECX  (want 0x00000003)"
if [[ "$ECX" != "0x00000003" ]]; then
  echo "FATAL: the #GP was delivered but the program did not complete normally."
  echo "       ecx=$ECX means the handler did not run to its increment, or ran twice."
  exit 1
fi
echo "  SEG-POSITIVE-OK: limit-load, limit-store and read-only-write all faulted;"
echo "                   neither violating store reached memory; test completed"

echo
echo "=== 4. NEGATIVE: the check must reject NOTHING across the system corpus ==="
TESTS="pseg pmode ppage pxpage pintr pintr16 pfault pfcpl3 pde pcpl pssiret pstk16 pdf ptask ptaskcpl ptaskv86 pdebug ppopf pv86"
TOTAL=0; NRUN=0; C03=0
for t in $TESTS; do
  TIMG="$REPO/verif/sys/tests/$t/$t.bin"
  [[ -f "$TIMG" ]] || continue
  NRUN=$((NRUN+1))
  RAW="$("$TB" --image "$TIMG" --system --out /dev/null --max-insn 1200 --quiesce 400 \
        +ven_seglog +ven_xpagelog 2>&1 || true)"
  N="$(printf '%s\n' "$RAW" | grep -c SEGCHK || true)"
  TOTAL=$((TOTAL+N))
  # REVIEW1_Aug2 C-03: count the PAGING/C-03 assertions in the SAME sweep. Both of
  # them -- the address-mirror drift (CHECK 5) and the new unsplit page-crossing
  # diagnostic -- were firing into the void: nothing in verif/ grepped for either, so
  # a real firing would have printed and been ignored, exactly the class of miss that
  # the M-08 exit-code bug was.
  C="$(printf '%s\n' "$RAW" | grep -c 'PAGING/C-0' || true)"
  C03=$((C03+C))
  if [[ "$C" != "0" ]]; then
    echo "  $t: $C PAGING/C-03 assertion firing(s)"
    printf '%s\n' "$RAW" | grep -E 'PAGING/C-0[34]' | head -2
  fi
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
echo "=== 5. C-03: the address mirror and the page-crossing extent must both hold ==="
echo "  PAGING/C-03+C-04 assertion firings across $NRUN system tests: $C03 (want 0)"
if [[ "$C03" != "0" ]]; then
  echo "FATAL: a PAGING/C-03 or C-04 assertion fired. Either cur_lin and mem_addr disagree for"
  echo "       some state (the address-mirror drift this pair has suffered before), or"
  echo "       an access straddled a page boundary in a state that cannot SPLIT it --"
  echo "       in which case the tail bytes went through the wrong physical page."
  exit 1
fi
echo "  C03-OK: address mirror agrees, and no unsplit page-crossing access occurred"

echo
echo "=== 6. C-01: a violation must not DEADLOCK the DEFAULT build ==="
# REVIEW2_aug2 C-01: seg_access_fault was computed UNCONDITIONALLY while delivery lived
# under `ifdef VEN_SEG_ENFORCE and the bus-driver squash was likewise unconditional. In
# the default build that gave: fault asserts -> request suppressed -> no #GP started ->
# the FSM waits forever for an ack that can never arrive.
#
# This gate could not see it: every check above builds with +define+VEN_SEG_ENFORCE.
# Hence a DEFAULT-BUILD case, and it needs a witness rather than an instruction count --
# the TB reports "quiescent (core idle)" for a NORMAL exit too (pseglim included), so
# "fewer instructions" cannot tell completion from a hang. psegdl parks 0x5eed11fe in ebp
# immediately before its isa-debug-exit; reaching that value IS the liveness assertion.
#
#   measured pre-fix  default build ebp = 0x00000000   (hung on the violating load)
#   measured post-fix default build ebp = 0x5eed11fe   (both accesses completed)
DEFTB="$REPO/verif/tb/obj_dir/tb_ventium"
make -s -C "$REPO/verif/sys/tests/psegdl" >/dev/null 2>&1 || true
DLIMG="$REPO/verif/sys/tests/psegdl/psegdl.bin"
if [[ -x "$DEFTB" && -f "$DLIMG" ]]; then
  "$DEFTB" --system --image "$DLIMG" --out "$REPO/build/sys/psegdl.vtrace" \
      --max-insn 500 --quiesce 300 >/dev/null 2>&1 || true
  DLEBP="$(tail -1 "$REPO/build/sys/psegdl.vtrace" 2>/dev/null | \
           python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("ebp"))' 2>/dev/null)"
  echo "  default-build liveness witness ebp = ${DLEBP:-<none>}  (want 0x5eed11fe)"
  if [[ "$DLEBP" != "0x5eed11fe" ]]; then
    echo "FATAL: a segment violation DEADLOCKED the default build."
    echo "       seg_access_fault must not be computed in a build that cannot DELIVER"
    echo "       the fault -- the squash suppresses the access and the FSM then waits"
    echo "       forever for an acknowledgement that can never arrive."
    exit 1
  fi
  echo "  C01-OK: a violating load+store complete in the default build (no deadlock)"
else
  echo "  SKIP: default TB or psegdl.bin missing"
fi

echo
echo "SEG-GATE-OK  (C-06: per-access segment limits enforced; positive + negative)"
