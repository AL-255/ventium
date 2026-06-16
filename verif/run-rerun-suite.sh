#!/usr/bin/env bash
# Comprehensive verification re-run after the FP-area-shrink + uop-cache +
# cycle-fidelity commits. Runs every routine gate, never aborts on failure,
# logs each gate separately, appends a one-line verdict to SUMMARY.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/build/verify-rerun"; mkdir -p "$OUT"
SUM="$OUT/SUMMARY.txt"; : > "$SUM"
echo "rerun suite @ $(git -C "$REPO" rev-parse --short HEAD) start" | tee -a "$SUM"

run () {  # run <name> <make-target-or-cmd...>
  local name="$1"; shift
  local log="$OUT/$name.log"
  echo "=== [$name] START ===" | tee -a "$SUM"
  ( cd "$REPO" && "$@" ) >"$log" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then echo "[$name] PASS (rc=0)" | tee -a "$SUM"
  else                   echo "[$name] FAIL (rc=$rc) -> $log" | tee -a "$SUM"; fi
  return 0
}

# Umbrella: verify + verify-sys + verify-soc + verify-srt + m6 + bus + bus-sva
run verify-all   make verify-all
# Cycle bands (default + the gated FP-overlap/FXCH variants wired in run-m5.sh)
run m5           make m5
# Standalone synthesizable FP/INT engine gates (separate obj_dirs)
run srt-iter     make verify-srt-iter
run idiv         make verify-idiv
run bcd          make verify-bcd
run fbld         make verify-fbld
run fppipe       make verify-fppipe

echo "=== SUITE DONE @ $(date -u +%H:%M:%SZ) ===" | tee -a "$SUM"
echo "---- verdict tally ----" | tee -a "$SUM"
grep -E '\] (PASS|FAIL) ' "$SUM" | tee -a "$SUM" >/dev/null
grep -cE '\] PASS '  "$SUM" | xargs echo "PASS:" | tee -a "$SUM"
grep -cE '\] FAIL '  "$SUM" | xargs echo "FAIL:" | tee -a "$SUM"
