#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Regression for the deliberately narrow common-base system fast path.
#
# Functional equivalence alone cannot prove the intended implementation path:
# the slow FSM is architecturally equivalent.  This gate therefore builds an
# isolated profile with VEN_SYS_FASTPATH + VEN_SYS_FASTPATH_RELOC and the
# simulation-only profiler, then requires the generic psysfpreloc client to
# both match QEMU and spend its long register-only loop in S_PIPE.  The program
# itself has no Quake dependency and no restored/saved guest state.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST=psysfpreloc
TDIR="$REPO/verif/sys/tests/$TEST"
OUTDIR="$REPO/build/sys"
OBJDIR="${OBJDIR:-obj_dir_sysfp_reloc_gate}"
TB="$REPO/verif/tb/$OBJDIR/tb_ventium"
LOG="$OUTDIR/$TEST.reloc.profile.log"
RTL_OUT="$OUTDIR/$TEST.reloc.rtl.sys.vtrace"
GOLD="$OUTDIR/$TEST.sys.vtrace"

say(){ echo; echo "=== $* ==="; }

say "1. refresh QEMU golden and canonical system differential"
bash "$REPO/verif/sys/run-sys-golden.sh" "$TEST"

say "2. build isolated relocated-fast-path profile"
make -C "$REPO/verif/tb" rtl OBJDIR="$OBJDIR" \
  VL_EXTRA_DEFINES='+define+VEN_SYS_FASTPATH +define+VEN_SYS_FASTPATH_RELOC +define+VEN_PERF_PROFILE' \
  >/dev/null
[[ -x "$TB" ]] || { echo "FATAL: relocated profile TB missing: $TB"; exit 1; }

say "3. run common-base client and require architectural equivalence"
"$TB" --image "$TDIR/psysfpreloc.bin" --system --out "$RTL_OUT" \
  --max-insn 1000 --quiesce 400 >"$LOG" 2>&1
python3 "$REPO/verif/diff/compare.py" --mode func --all "$GOLD" "$RTL_OUT"

# The client contains 128 iterations x five register/relative instructions.
# In the qualifying profile, those retire through S_PIPE.  Setup, segment
# loads, cache warm-up and the terminal I/O remain slow by design.  A 300-clock
# bail bound leaves room for those fixed costs but fails the base-zero-only
# guard (currently 733 bails); the >=400 issue bound independently prevents an
# accidental accounting-only pass.
# The profiler right-aligns the bucket number, so the counter is $3 for [ 9]
# but $2 for [12].  Select the first all-decimal field rather than depending
# on that presentation detail.
BAIL="$(awk '/\[ *9\].*fp_sys_bail/{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOG")"
ISSUE="$(awk '/\[ *12\].*ISSUE/{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOG")"
[[ "$BAIL" =~ ^[0-9]+$ ]] || { echo "FATAL: profiler did not report fp_sys_bail"; exit 1; }
[[ "$ISSUE" =~ ^[0-9]+$ ]] || { echo "FATAL: profiler did not report S_PIPE issue"; exit 1; }
echo "  profile: fp_sys_bail=$BAIL  S_PIPE issues=$ISSUE"
if (( BAIL >= 300 || ISSUE < 400 )); then
  echo "FATAL: common-base register-only loop did not enter the relocated fast path"
  echo "       expected fp_sys_bail < 300 and S_PIPE issues >= 400; see $LOG"
  exit 1
fi

echo "SYS-FPRELOC-GATE-OK  (QEMU-equivalent common-base client; relocated S_PIPE exercised)"
