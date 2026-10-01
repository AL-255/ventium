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
#      Standard pselnull uses legal SS-qualified accesses and visible-null
#      checks in A/E; all five terminal witnesses and exactly its designed
#      case-C GP0004 / case-D TS0004 pair are required, without a cascade
#      exception. pnullseg separately grades strict null-data #GP(0).
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
echo "=== 3b. R2-H07 POSITIVE: the decoded-extent fetch limit check (pfetchlim) ==="
# pfetchlim runs five one-case code segments with limit 0x3F, each entered by a
# far jump at a precise offset (verif/sys/tests/pfetchlim/manifest.json):
#   A  (0x18, entry 0x3E) 2-byte jmp ending exactly AT the limit -> legal,
#      NO fault in EITHER build (the at-limit false-positive tripwire)
#   B  (0x20, entry 0x3C) 5-byte movl %eax,0x30000 straddling    -> #GP(0)
#      pre-issue, and the store must NOT commit (witness @0x30000)
#   C1 (0x28, entry 0x3F) 2-byte mov %al,(%ebx) starting AT the limit and
#      ending past it                                          -> #GP(0), no commit
#   C2 (0x30, entry 0x3B) 6-byte addl %eax,0x30008 straddling    -> #GP(0), no commit
#   C3 (0x38, entry 0x3E) 2-byte jmp +0 ending at the limit, so the next fetch
#      STARTS past it -> #GP(0) from the older first-byte check (cs_fetch_fault,
#      H-05), cross-checked here beside the new extent check.
# Enforcement-build only: cs_extent_fault is compiled out of the default build,
# and QEMU's translator checks only the fetch START address, so there is no
# differential oracle for the extent case -- this grades against the SDM by
# fault count, fault PCs and no-commit witnesses, exactly like section 3.
make -s -C verif/sys/tests/pfetchlim >/dev/null 2>&1
PFIMG="$REPO/verif/sys/tests/pfetchlim/pfetchlim.bin"
[[ -f "$PFIMG" ]] || { echo "FATAL: pfetchlim.bin missing"; exit 1; }
PFOUT="$REPO/build/sys/pfetchlim.seg.vtrace"
PFLOG="$("$TB" --image "$PFIMG" --system --out "$PFOUT" --max-insn 2000 --quiesce 400 \
        +ven_faultlog 2>&1 || true)"
NPF="$(printf '%s\n' "$PFLOG" | grep -c 'vec=13 ' || true)"
echo "  #GP(13) deliveries: $NPF (want 4: B/C1/C2 straddling + C3 starting past the limit)"
if [[ "$NPF" != "4" ]]; then
  echo "FATAL: expected exactly FOUR #GP(0); got $NPF."
  echo "       <4 = an extent violation was not caught (enforcement inert)."
  echo "       >4 = a legal instruction faulted. Case A ends exactly AT the limit"
  echo "            and must not fault -- that false-positive class is how this"
  echo "            finding's deliveries got reverted in earlier rounds."
  printf '%s\n' "$PFLOG" | grep FAULT | head -8
  exit 1
fi
# Every #GP must be stamped at the OFFENDING instruction. The stamps are
# CS-relative offsets, so they are layout constants: B at 0x3c, C1 at 0x3f,
# C2 at 0x3b, and C3's first-byte fetch fault at 0x40. A stamp anywhere else --
# e.g. 0x3e, the at-limit control or C3's legal 2-byte hop -- is a mis-aimed
# check even when the count is right.
PFPCS="$(printf '%s\n' "$PFLOG" | sed -n 's/.*vec=13 .*pc=\([0-9a-f]*\).*/\1/p' | sort | tr '\n' ' ')"
echo "  fault PCs (sorted): ${PFPCS}(want 0000003b 0000003c 0000003f 00000040)"
if [[ "$PFPCS" != "0000003b 0000003c 0000003f 00000040 " ]]; then
  echo "FATAL: a #GP was stamped somewhere other than the offending instruction."
  echo "       0x3e in the set means a LEGAL at-limit instruction was extent-faulted"
  echo "       -- check the (eip, d_len) pairing at the S_PIPE evaluation point"
  echo "       with +ven_seglog ([SEGCHK-X] lines show the pair the check used)."
  printf '%s\n' "$PFLOG" | grep FAULT | head -8
  exit 1
fi
# The faults must SUPPRESS the straddling accesses, not merely follow them:
# ebp/edi/esi carry the seeds of the three side-effect witnesses.
PFECX="$(tail -1 "$PFOUT" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read())["ecx"])')"
PFEBP="$(tail -1 "$PFOUT" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read())["ebp"])')"
PFEDI="$(tail -1 "$PFOUT" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read())["edi"])')"
PFESI="$(tail -1 "$PFOUT" | python3 -c 'import sys,json;print(json.loads(sys.stdin.read())["esi"])')"
echo "  ecx (#GP counter) = $PFECX (want 0x00000004)"
echo "  witnesses: ebp=$PFEBP edi=$PFEDI esi=$PFESI (want the seeds)"
if [[ "$PFECX" != "0x00000004" ]]; then
  echo "FATAL: the #GPs were delivered but the program did not complete normally."
  exit 1
fi
if [[ "$PFEBP" != "0x5eedb005" ]]; then
  echo "FATAL: the case-B straddling STORE (5 bytes) committed -- 0xcafebabe means"
  echo "       the extent #GP followed the access instead of suppressing it."
  exit 1
fi
if [[ "$PFEDI" != "0x5eedc101" ]]; then
  echo "FATAL: the case-C1 straddling byte STORE (2 bytes, starts AT the limit)"
  echo "       committed -- low byte 0xa5 means the store reached memory."
  exit 1
fi
if [[ "$PFESI" != "0x5eedc202" ]]; then
  echo "FATAL: the case-C2 straddling RMW (6 bytes) committed -- the addend was applied."
  exit 1
fi
echo "  H07-POSITIVE-OK: 2/5/6-byte straddlers and the past-limit fetch all #GP'd"
echo "                   pre-commit; the at-limit control faulted in NEITHER build"

# Anti-vacuity, default build: with both fetch checks compiled out the same
# image must take ZERO faults and every side effect must COMMIT -- otherwise the
# intact witnesses above prove nothing. (DEFTB is defined in section 6 below;
# set it here if this block runs before it.)
DEFTB="${DEFTB:-$REPO/verif/tb/obj_dir/tb_ventium}"
if [[ -x "$DEFTB" ]]; then
  "$DEFTB" --system --image "$PFIMG" --out "$REPO/build/sys/pfetchlim_def.vtrace" \
      --max-insn 2000 --quiesce 400 +ven_faultlog \
      >"$REPO/build/sys/pfetchlim_def.log" 2>&1 || true
  PFDEFN="$(grep -c 'vec=13 ' "$REPO/build/sys/pfetchlim_def.log" || true)"
  PFDEBP="$(tail -1 "$REPO/build/sys/pfetchlim_def.vtrace" 2>/dev/null | \
           python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("ebp"))' 2>/dev/null)"
  PFDECL="$(tail -1 "$REPO/build/sys/pfetchlim_def.vtrace" 2>/dev/null | \
           python3 -c 'import sys,json;r=json.loads(sys.stdin.read());print(r.get("edi"),r.get("esi"))' 2>/dev/null)"
  echo "  default build: $PFDEFN #GP(s) (want 0); ebp=${PFDEBP:-<none>} edi/esi=${PFDECL:-<none>}"
  echo "                 (want ebp=0xcafebabe edi/esi=0x5eedc1a5 0x6ffed313 -- all committed)"
  if [[ "$PFDEFN" != "0" ]]; then
    echo "FATAL: the DEFAULT build took a fetch-limit #GP. Both cs_fetch_fault and"
    echo "       cs_extent_fault must be compiled out without +define+VEN_SEG_ENFORCE."
    exit 1
  fi
  if [[ "$PFDEBP" != "0xcafebabe" ]]; then
    echo "FATAL: the default build did not commit the case-B store, so the enforced"
    echo "       run's intact witness proves nothing (anti-vacuity failure)."
    exit 1
  fi
  echo "  H07-ANTIVACUITY-OK: default build faults nowhere and commits every side effect"
else
  echo "  SKIP: default TB missing (anti-vacuity control not run)"
fi

echo
echo "=== 4. NEGATIVE: the check must reject NOTHING across the system corpus ==="
TESTS="pseg pmode ppage pxpage pintr pintr16 pfault pfcpl3 pde pcpl pssiret pstk16 pdf ptask ptaskcpl ptaskv86 pdebug ppopf pv86 pcalltss ptaskpg pretfoutpg pjmpgate pltr pretfres piopermwrap piretgp0 pxfer pselnull pxprobe pcgparam pcg16 pcgpg pxc04 pxc04i pxc04f pxc04e pxc04t pxc04m"
# REVIEW1_Aug3 R2-C03: ALL SIX ex-xc04 producers join the sweep (none may fire a
# PAGING/C-0* assertion now that the fragment engine covers them) -- pxc04
# (S_LGDT read) included since the walk-freeze fix (fx_walk_hold). pxprobe
# (R2-C04 frame probe) and the R2-H05 call-gate suites (pcgparam/pcg16/pcgpg,
# measured SEGCHK=0 over the sweep's 1200-insn window) join the same sweep.
TOTAL=0; NRUN=0; C03=0
for t in $TESTS; do
  TIMG="$REPO/verif/sys/tests/$t/$t.bin"
  [[ -f "$TIMG" ]] || continue
  NRUN=$((NRUN+1))
  STRACE=/dev/null
  if [[ "$t" == "pselnull" ]]; then
    STRACE="$REPO/build/sys/pselnull_seg.vtrace"
    SLOG="$REPO/build/sys/pselnull_seg.log"
    SRC=0
    timeout --kill-after=3s 30s "$TB" --image "$TIMG" --system --cosim \
      --out "$STRACE" --max-insn 1200 --max-cycles 1000000 --quiesce 400 \
      +ven_seglog +ven_xpagelog +ven_faultlog >"$SLOG" 2>&1 || SRC=$?
    RAW="$(<"$SLOG")"
  else
    RAW="$("$TB" --image "$TIMG" --system --out "$STRACE" --max-insn 1200 --quiesce 400 \
          +ven_seglog +ven_xpagelog +ven_faultlog 2>&1 || true)"
  fi
  N="$(printf '%s\n' "$RAW" | grep -c SEGCHK || true)"
  # Standard pselnull A/E now use legal SS-relative sentinels plus visible-null
  # checks. No cascade/prefix exception: the whole five-case flow must finish
  # without PF or any fault beyond the existing intentional C/D pair. Strict
  # null-data-use/no-effect GP0 is independently covered by pnullseg.
  if [[ "$t" == "pselnull" ]]; then
    timeout --kill-after=3s 10s python3 "$REPO/verif/sys/tests/pselnull/check_witness.py" \
      --trace "$STRACE" --log "$SLOG" --return-code "$SRC" \
      --elf "$REPO/verif/sys/tests/pselnull/pselnull.elf"
    echo "  $t: all five witnesses, exact C/D faults, genuine closed debug-exit133"
  fi
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

# ---- REVIEW2_aug2 H-05: the INSTRUCTION-FETCH CS-limit check ------------------
# The per-access check is qualified on cur_is_d (a fetch measured against the DS limit
# is the spurious #GP this delivery was reverted for), which left fetches checked by
# nothing: EIP could leave the code segment and the core kept fetching.
#
# pcslim runs inside a 16-byte code segment; 16 NOPs fill offsets 0..15 and the
# instruction at offset 16 is outside. Both halves are asserted, because the poison
# witness is what proves the test actually REACHES the out-of-limit fetch:
#
#   enforcing build  ebp = 0x0C510010  -> #GP, and the faulting EIP is exactly 16
#   default build    ebp = 0xBADBAD00  -> no enforcement, the code past the limit RAN
#
echo
echo "=== H-05: instruction fetch must be checked against the CS limit ==="
CSIMG="$REPO/verif/sys/tests/pcslim/pcslim.bin"
if [[ -f "$CSIMG" ]]; then
  "$TB" --system --image "$CSIMG" --out "$REPO/build/sys/pcslim.vtrace" \
      --max-insn 4000 --quiesce 400 >/dev/null 2>&1 || true
  CSEBP="$(tail -1 "$REPO/build/sys/pcslim.vtrace" 2>/dev/null | \
           python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("ebp"))' 2>/dev/null)"
  echo "  enforcing-build witness ebp = ${CSEBP:-<none>}  (want 0x0c510010)"
  if [[ "$CSEBP" != "0x0c510010" ]]; then
    echo "FATAL: the fetch at offset 16 was NOT rejected against a limit of 15."
    echo "       0xbadbad00 means the out-of-limit instruction EXECUTED; anything else"
    echo "       means the test faulted somewhere other than the fetch it targets."
    exit 1
  fi
  echo "  H05-FETCH-OK: #GP raised at EIP=16, the first byte outside CS.limit"

  if [[ -x "$DEFTB" ]]; then
    "$DEFTB" --system --image "$CSIMG" --out "$REPO/build/sys/pcslim_def.vtrace" \
        --max-insn 4000 --quiesce 400 >/dev/null 2>&1 || true
    CSDEF="$(tail -1 "$REPO/build/sys/pcslim_def.vtrace" 2>/dev/null | \
             python3 -c 'import sys,json;print(json.loads(sys.stdin.read()).get("ebp"))' 2>/dev/null)"
    echo "  default-build control    ebp = ${CSDEF:-<none>}  (want 0xbadbad00)"
    if [[ "$CSDEF" != "0xbadbad00" ]]; then
      echo "FATAL: the DEFAULT build did not run past the limit, so this test is not"
      echo "       exercising the fetch path and the check above proves nothing."
      exit 1
    fi
    echo "  H05-ANTIVACUITY-OK: the default build really does fetch past CS.limit"
  fi
else
  echo "  SKIP: pcslim.bin missing (make -C verif/sys/tests/pcslim)"
fi

echo
echo "SEG-GATE-OK  (C-06: per-access segment limits enforced; positive + negative)"
