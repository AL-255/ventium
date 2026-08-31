#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# QEMU differential + implementation-path regression for the guarded system
# fast-store subset. The image first makes its single MOV [disp32],r32 fault
# against a present/read-only page, then restarts it and runs 128 stores. A
# correct trace alone is insufficient (the slow FSM is equivalent), so the
# profiler must also show the restarted loop issuing through S_PIPE. One final
# dword crossing 0x400fff must instead take the mature slow fragment path.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST=pfaststore
TDIR="$REPO/verif/sys/tests/$TEST"
OUTDIR="${OUTDIR:-$REPO/build/sys}"
export OUTDIR
OBJDIR="${OBJDIR:-obj_dir_sysfp_faststore_gate}"
# Avoid a concurrent C++ rebuild exhausting a verification host. Callers can
# raise this deliberately on a provisioned CI machine; the developer-safe
# default is one compiler job.
VL_J="${VL_J:-1}"
TB="${TB_BIN:-$REPO/verif/tb/$OBJDIR/tb_ventium}"
LOG="$OUTDIR/$TEST.faststore.profile.log"
BUILD_LOG="$OUTDIR/$TEST.faststore.build.log"
RTL_OUT="$OUTDIR/$TEST.faststore.rtl.sys.vtrace"
GOLD="$OUTDIR/$TEST.sys.vtrace"

say(){ echo; echo "=== $* ==="; }

say "1. refresh QEMU golden"
bash "$REPO/verif/sys/run-sys-golden.sh" "$TEST"

if [[ -n "${TB_BIN:-}" ]]; then
  say "2. use caller-supplied isolated system-fast-store profile"
  [[ -x "$TB" ]] || { echo "FATAL: TB_BIN is not executable: $TB"; exit 1; }
  echo "  using prebuilt simulator: $TB"
else
  say "2. build isolated system-fast-store profile"
  if ! make -C "$REPO/verif/tb" rtl OBJDIR="$OBJDIR" VL_J="$VL_J" \
    VL_EXTRA_DEFINES='+define+VEN_SYS_FASTPATH +define+VEN_SYS_FASTPATH_RELOC +define+VEN_SYS_FASTLOAD_FLAT +define+VEN_SYS_FASTSTORE_FLAT +define+VEN_PERF_PROFILE' \
    >"$BUILD_LOG" 2>&1; then
    echo "FATAL: fast-store profile build failed; tail of $BUILD_LOG:"
    tail -n 80 "$BUILD_LOG"
    exit 1
  fi
  [[ -x "$TB" ]] || { echo "FATAL: fast-store TB missing: $TB"; exit 1; }
fi

say "3. compare the protection-fault/restart trace against QEMU"
"$TB" --system --image "$TDIR/$TEST.bin" --out "$RTL_OUT" --max-insn 1400 \
  --quiesce 8000 +ven_faultlog >"$LOG" 2>&1
python3 "$REPO/verif/diff/compare.py" --mode func --all "$GOLD" "$RTL_OUT"

python3 - "$RTL_OUT" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])
           if line.strip() and not line.startswith('{"vtrace"')]
assert records, "no trace records"
r = records[-1]
h = lambda name: int(r[name], 16)
assert h("ecx") == 3, f"ecx={r['ecx']}: expected #PF/#GP/#UD witnesses"
assert h("edx") == 0x004000f4, f"edx={r['edx']}: CR2/exit witness mismatch"
assert h("edi") == 3, f"edi={r['edi']}: #PF error is not P|W=3"
assert h("esi") == 0xCAFEBABE, f"esi={r['esi']}: faulting store escaped before restart"
print(f"  final witnesses: ecx=3 edx={r['edx']} edi=3 esi=cafebabe")
PY

PF=$(grep -c '^\[FAULT\] vec=14 .*err=00000003' "$LOG" || true)
GP=$(grep -c '^\[FAULT\] vec=13 .*err=00000038' "$LOG" || true)
ALL=$(grep -c '^\[FAULT\] vec=' "$LOG" || true)
[[ "$PF" = 1 && "$GP" = 1 && "$ALL" = 2 ]] || {
  echo "FATAL: #PF(err=3)=$PF #GP(err=38)=$GP all=$ALL (want 1/1/2)"
  exit 1
}

ISSUE="$(awk '/\[ *12\].*ISSUE/{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOG")"
[[ "$ISSUE" =~ ^[0-9]+$ ]] || { echo "FATAL: profiler did not report S_PIPE issue"; exit 1; }
echo "  profile: S_PIPE issues=$ISSUE"
if (( ISSUE < 120 )); then
  echo "FATAL: restarted MOV [disp32],r32 loop did not enter the fast store path"
  echo "       expected S_PIPE issues >= 120; see $LOG"
  exit 1
fi

MEM_BAIL="$(awk '/system memory not eligible/{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' "$LOG")"
[[ "$MEM_BAIL" =~ ^[0-9]+$ ]] || { echo "FATAL: profiler did not report system-memory bail"; exit 1; }
if (( MEM_BAIL != 1 )); then
  echo "FATAL: page-crossing MOV [0x400fff],r32 was not the one slow-path memory fallback (got $MEM_BAIL)"
  exit 1
fi

echo "SYS-FASTSTORE-GATE-OK  (QEMU-equivalent fault/restart; S_PIPE loop + one crossing slow-path fallback)"
