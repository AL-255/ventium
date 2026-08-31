#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Regression for the deliberately narrow common-base system fast-memory path.
# Functional equivalence alone cannot prove that an admitted DS/SS memory access retired through
# S_PIPE rather than the slow FSM.  This gate builds an isolated profile with
# VEN_SYS_FASTPATH, VEN_SYS_FASTPATH_RELOC, VEN_SYS_FASTLOAD_FLAT,
# VEN_SYS_FASTSTORE_FLAT and the
# simulation-only profiler.  The generic client has a non-zero, shared CS/DS/
# SS/ES base, enables a non-identity 4 KiB page mapping for the client, and
# uses admitted DS base+displacement/SIB/literal forms plus SS-default EBP and
# ESP bases in its hot loop, for both full-dword MOV reads and stores.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST=psysfpload
TDIR="$REPO/verif/sys/tests/$TEST"
OUTDIR="${OUTDIR:-$REPO/build/sys}"
export OUTDIR
OBJDIR="${OBJDIR:-obj_dir_sysfp_fastload_gate}"
# Keep define-variant Verilator builds bounded unless the invoking harness
# explicitly chooses a different host-concurrency budget.
VL_J="${VL_J:-1}"
TB="${TB_BIN:-$REPO/verif/tb/$OBJDIR/tb_ventium}"
LOG="$OUTDIR/$TEST.fastload.profile.log"
BUILD_LOG="$OUTDIR/$TEST.fastload.build.log"
RTL_OUT="$OUTDIR/$TEST.fastload.rtl.sys.vtrace"
GOLD="$OUTDIR/$TEST.sys.vtrace"

say(){ echo; echo "=== $* ==="; }

say "1. refresh QEMU golden and canonical system differential"
bash "$REPO/verif/sys/run-sys-golden.sh" "$TEST"

if [[ -n "${TB_BIN:-}" ]]; then
  say "2. use caller-supplied isolated relocated fast-memory profile"
  [[ -x "$TB" ]] || { echo "FATAL: TB_BIN is not executable: $TB"; exit 1; }
  echo "  using prebuilt simulator: $TB"
else
  say "2. build isolated relocated fast-memory profile"
  if ! make -C "$REPO/verif/tb" rtl OBJDIR="$OBJDIR" VL_J="$VL_J" \
    VL_EXTRA_DEFINES='+define+VEN_SYS_FASTPATH +define+VEN_SYS_FASTPATH_RELOC +define+VEN_SYS_FASTLOAD_FLAT +define+VEN_SYS_FASTSTORE_FLAT +define+VEN_PERF_PROFILE' \
    >"$BUILD_LOG" 2>&1; then
    echo "FATAL: fast-load profile build failed; tail of $BUILD_LOG:"
    tail -n 80 "$BUILD_LOG"
    exit 1
  fi
  [[ -x "$TB" ]] || { echo "FATAL: fast-load profile TB missing: $TB"; exit 1; }
fi

say "3. run common-base client and require architectural equivalence"
"$TB" --image "$TDIR/psysfpload.bin" --system --out "$RTL_OUT" \
  --max-insn 7000 --quiesce 400 >"$LOG" 2>&1
python3 "$REPO/verif/diff/compare.py" --mode func --all "$GOLD" "$RTL_OUT"

# The client repeats ten checked reads and eight matching checked MOV stores
# after CR3/CR0.PG enable: five DS base/SIB forms, literal disp32, and two
# SS-default EBP/ESP-base forms. Every form repeats 128 times. The bail floor
# catches a store silently falling back to the slow FSM; the S_PIPE floor
# independently rejects accounting-only admission. The modest slack retains
# room for setup, descriptor loads, cache warm-up, and terminal I/O.
BAIL="$(awk '/\[ *9\].*fp_sys_bail/{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOG")"
ISSUE="$(awk '/\[ *12\].*ISSUE/{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOG")"
[[ "$BAIL" =~ ^[0-9]+$ ]] || { echo "FATAL: profiler did not report fp_sys_bail"; exit 1; }
[[ "$ISSUE" =~ ^[0-9]+$ ]] || { echo "FATAL: profiler did not report S_PIPE issue"; exit 1; }
echo "  profile: fp_sys_bail=$BAIL  S_PIPE issues=$ISSUE"
if (( BAIL >= 1000 || ISSUE < 4250 )); then
  echo "FATAL: common-base DS/SS effective-address loop did not enter every audited fast-memory form"
  echo "       expected fp_sys_bail < 1000 and S_PIPE issues >= 4250; see $LOG"
  exit 1
fi

echo "SYS-FPLOAD-GATE-OK  (QEMU-equivalent common-base DS/SS reads+stores; S_PIPE exercised)"
