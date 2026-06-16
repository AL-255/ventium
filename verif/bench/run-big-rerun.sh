#!/usr/bin/env bash
# Big-test re-run after the FP-area-shrink + uop-cache + cycle-fidelity commits.
#  (1) deep-sweep: 19-config PER-INSTRUCTION lockstep differential vs the gdbstub
#      golden (coremark x4, whetstone, stream, dhrystone, linpack, 12 kernels,
#      Quake 30M) — streaming compare, x87 graded.
#  (2) free-run to COMPLETION (output vs qemu-native): coremark (CRC validation),
#      whetstone (FP), and the Quake framebuffer demo.
# Never aborts on one failure; logs each; prints a final tally.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO/build/big-rerun"; mkdir -p "$OUT"
SUM="$OUT/SUMMARY.txt"; : > "$SUM"
JOBS="${JOBS:-4}"
say(){ echo "$@" | tee -a "$SUM"; }
say "big-rerun @ $(git -C "$REPO" rev-parse --short HEAD)  JOBS=$JOBS  start $(date -u +%H:%M:%SZ)"

say "== build RTL TB once (obj_dir; emulator linked in) =="
make -C "$REPO/verif/tb" rtl >"$OUT/build.log" 2>&1 \
  && say "[build] OK" || { say "[build] FAIL -> $OUT/build.log"; exit 1; }

# ---- (2) free-runs to completion, in the background ----
# coremark canonical 4000 iters (~1.45G insns; validates "Correct operation").
( bash "$REPO/verif/bench/run-freerun.sh" coremark 2500000000 - -- 0x0 0x0 0x66 4000 \
    >"$OUT/fr_coremark.log" 2>&1; echo $? >"$OUT/fr_coremark.rc" ) &
CM=$!
# whetstone to completion (heavy x87 — exercises the shrunk FP datapath).
( bash "$REPO/verif/bench/run-freerun.sh" whetstone 1500000000 \
    >"$OUT/fr_whetstone.log" 2>&1; echo $? >"$OUT/fr_whetstone.rc" ) &
WH=$!
# Quake free-run framebuffer demo (FP-divide + integer texturing + uop-cache).
( bash "$REPO/verif/bench/run-quake-fb.sh" 120000000 8 \
    >"$OUT/fr_quake.log" 2>&1; echo $? >"$OUT/fr_quake.rc" ) &
QK=$!
say "[freerun] launched: coremark(pid $CM) whetstone(pid $WH) quake-fb(pid $QK)"

# ---- (1) deep-sweep in the foreground (it builds rtl again = no-op) ----
say "== deep-sweep (19 configs, $JOBS parallel) — per-instruction differential =="
bash "$REPO/verif/bench/run-deep-sweep.sh" "$JOBS" >"$OUT/deep-sweep.log" 2>&1
say "[deep-sweep] finished rc=$? (see deep-sweep.log)"

say "== waiting on free-run completions =="
wait $CM $WH $QK 2>/dev/null

# ---- tally ----
say "================= BIG-RERUN SUMMARY $(date -u +%H:%M:%SZ) ================="
say "--- deep-sweep per-config ---"
grep -E 'DEEP-LOCKSTEP-(OK|DIVERGENT)|PRODUCER-FAIL|TB-FAIL|SUMMARY|FAIL=' "$OUT/deep-sweep.log" 2>/dev/null | tee -a "$SUM" >/dev/null
grep -E 'DEEP-LOCKSTEP-(OK|DIVERGENT)|FAIL=|configs.*(OK|FAIL)' "$OUT/deep-sweep.log" 2>/dev/null | tail -25 | tee -a "$SUM"
say "--- free-run verdicts ---"
for f in coremark whetstone quake; do
  rc=$(cat "$OUT/fr_$f.rc" 2>/dev/null || echo '??')
  if [ "$rc" = 0 ]; then say "[freerun:$f] PASS (rc=0)"; else say "[freerun:$f] CHECK (rc=$rc) -> $OUT/fr_$f.log"; fi
done
say "=== BIG-RERUN DONE ==="
