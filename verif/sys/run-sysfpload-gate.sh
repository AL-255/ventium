#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Regression for the deliberately narrow common-base system fast-read path.
# Functional equivalence alone cannot prove that an admitted DS/SS memory read retired through
# S_PIPE rather than the slow FSM.  This gate builds an isolated profile with
# VEN_SYS_FASTPATH, VEN_SYS_FASTPATH_RELOC, VEN_SYS_FASTLOAD_FLAT and the
# simulation-only profiler.  The generic client has a non-zero, shared CS/DS/
# SS/ES base, enables a non-identity 4 KiB page mapping for the client, and
# uses admitted DS base+displacement/SIB/literal forms plus SS-default EBP and
# ESP bases in its hot loop.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST=psysfpload
TDIR="$REPO/verif/sys/tests/$TEST"
OUTDIR="$REPO/build/sys"
OBJDIR="${OBJDIR:-obj_dir_sysfp_fastload_gate}"
TB="$REPO/verif/tb/$OBJDIR/tb_ventium"
LOG="$OUTDIR/$TEST.fastload.profile.log"
BUILD_LOG="$OUTDIR/$TEST.fastload.build.log"
RTL_OUT="$OUTDIR/$TEST.fastload.rtl.sys.vtrace"
GOLD="$OUTDIR/$TEST.sys.vtrace"

say(){ echo; echo "=== $* ==="; }

say "1. refresh QEMU golden and canonical system differential"
bash "$REPO/verif/sys/run-sys-golden.sh" "$TEST"

say "2. build isolated relocated fast-load profile"
if ! make -C "$REPO/verif/tb" rtl OBJDIR="$OBJDIR" \
  VL_EXTRA_DEFINES='+define+VEN_SYS_FASTPATH +define+VEN_SYS_FASTPATH_RELOC +define+VEN_SYS_FASTLOAD_FLAT +define+VEN_PERF_PROFILE' \
  >"$BUILD_LOG" 2>&1; then
  echo "FATAL: fast-load profile build failed; tail of $BUILD_LOG:"
  tail -n 80 "$BUILD_LOG"
  exit 1
fi
[[ -x "$TB" ]] || { echo "FATAL: fast-load profile TB missing: $TB"; exit 1; }

say "3. run common-base client and require architectural equivalence"
"$TB" --image "$TDIR/psysfpload.bin" --system --out "$RTL_OUT" \
  --max-insn 5000 --quiesce 400 >"$LOG" 2>&1
python3 "$REPO/verif/diff/compare.py" --mode func --all "$GOLD" "$RTL_OUT"

# The client repeats ten checked reads after CR3/CR0.PG enable: five DS MOV
# base/SIB forms, literal-disp32 MOV, the two CMP operand orders, and two
# SS-default EBP/ESP-base MOVs. With all ten live it retires to quiescence at
# 4,245 instructions and measures 911 system bails and 3,336 S_PIPE issues.
# Every read form repeats 128 times: losing either SS form adds 128 bails and
# removes 128 issues, while the bounds retain room for unrelated accounting.
BAIL="$(awk '/\[ *9\].*fp_sys_bail/{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOG")"
ISSUE="$(awk '/\[ *12\].*ISSUE/{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOG")"
[[ "$BAIL" =~ ^[0-9]+$ ]] || { echo "FATAL: profiler did not report fp_sys_bail"; exit 1; }
[[ "$ISSUE" =~ ^[0-9]+$ ]] || { echo "FATAL: profiler did not report S_PIPE issue"; exit 1; }
echo "  profile: fp_sys_bail=$BAIL  S_PIPE issues=$ISSUE"
if (( BAIL >= 1000 || ISSUE < 3250 )); then
  echo "FATAL: common-base DS/SS effective-address loop did not enter every audited fast-read form"
  echo "       expected fp_sys_bail < 1000 and S_PIPE issues >= 3250; see $LOG"
  exit 1
fi

echo "SYS-FPLOAD-GATE-OK  (QEMU-equivalent common-base DS/SS reads; S_PIPE exercised)"
