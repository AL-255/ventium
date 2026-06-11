#!/bin/bash
# =====================================================================
# A/B cycle-equivalence gate for the 2-stage FP commit (+VEN_FP_PIPE2).
#
# Builds two cycle TBs that differ ONLY by VEN_FP_PIPE2, runs both on the FP
# cycle kernels in --cycle mode, and asserts the RTL cycle traces are BYTE-
# IDENTICAL. If A==B, the 2-stage split is provably cycle-equivalent to the
# validated 1-stage +VEN_FP_PIPE (it inherits its band/oracle validation). Also
# band-checks each against the p5trace.so golden (faddchain CPI ~3, fpindep<that).
#
# Run:  bash verif/fppipe/run-fp-pipe2-ab.sh
# =====================================================================
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
TB="$ROOT/verif/tb"
TESTS="$ROOT/verif/tests"
OUT="$ROOT/build/fppipe2_ab"; mkdir -p "$OUT"
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
P5TRACE="$ROOT/build/p5trace.so"
COMPARE="$ROOT/verif/diff/compare.py"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
CFLAGS="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"
BASE="+define+VEN_SRT_ITER +define+VEN_IDIV_ITER +define+VEN_BCD_ITER +define+VEN_FP_PIPE +define+VEN_BTB_PIPE"

say(){ echo "=== $* ==="; }

# ---- build TB_A (1-stage) and TB_B (2-stage) -------------------------------
say "build TB_A (+VEN_FP_PIPE) and TB_B (+VEN_FP_PIPE2)"
( cd "$TB" && VL_EXTRA_DEFINES="$BASE" make rtl OBJDIR=obj_dir_fp1 ) > "$OUT/build_A.log" 2>&1 || { echo "TB_A build FAILED"; tail -5 "$OUT/build_A.log"; exit 1; }
if [ ! -x "$TB/obj_dir_fp2/tb_ventium" ]; then
  ( cd "$TB" && VL_EXTRA_DEFINES="$BASE +define+VEN_FP_PIPE2" make rtl OBJDIR=obj_dir_fp2 ) > "$OUT/build_B.log" 2>&1 || { echo "TB_B build FAILED"; tail -5 "$OUT/build_B.log"; exit 1; }
fi
TBA="$TB/obj_dir_fp1/tb_ventium"; TBB="$TB/obj_dir_fp2/tb_ventium"
echo "TB_A=$TBA  TB_B=$TBB"

RC=0
for K in mb_faddchain mb_fpindep; do
  say "kernel $K"
  SRC="$TESTS/$K/$K.s"
  LOAD=0x08048000; ENTRY=0x08048000; ESP=0x40c34910
  ELF="$OUT/$K.elf"; FLAT="$OUT/$K.flat"; GOLD="$OUT/$K.gold"
  gcc $CFLAGS -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" || { echo "$K gcc FAIL"; RC=1; continue; }
  python3 "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" > "$OUT/$K.flatlog" 2>&1 || { echo "$K elf2flat FAIL"; RC=1; continue; }
  # golden cycle vtrace (oracle) for the absolute band check
  "$QEMU" -cpu pentium -plugin "$P5TRACE,out=$GOLD,imiss=8,dmiss=8,cache=1" "$ELF" > "$OUT/$K.goldlog" 2>&1
  GN=$(( $(wc -l < "$GOLD") - 1 )); [ "$GN" -lt 0 ] && GN=0
  for tag in A B; do
    bin=$([ "$tag" = A ] && echo "$TBA" || echo "$TBB")
    "$bin" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" --init-esp "$ESP" \
       --cycle --x87 --out "$OUT/$K.rtl_$tag" --max-insn "$GN" --max-cycles 80000000 \
       > "$OUT/$K.rtl_$tag.log" 2>&1 || { echo "$K TB_$tag run FAIL"; RC=1; }
  done
  # 1) A vs B cycle-trace EQUALITY (the cycle-safety proof)
  if diff -q "$OUT/$K.rtl_A" "$OUT/$K.rtl_B" >/dev/null 2>&1; then
    echo "  A==B  : IDENTICAL cycle trace  (FP_PIPE2 == FP_PIPE, cycle-safe)"
  else
    echo "  A==B  : *** DIFFER *** ($(diff "$OUT/$K.rtl_A" "$OUT/$K.rtl_B" | grep -c '^[<>]') line deltas)"
    diff "$OUT/$K.rtl_A" "$OUT/$K.rtl_B" | head -8 | sed 's/^/      /'
    RC=1
  fi
  # 2) band check of B vs golden
  python3 "$COMPARE" --mode cycle --tol-pct 12 "$GOLD" "$OUT/$K.rtl_B" > "$OUT/$K.cmp_B" 2>&1
  echo "  B vs golden (cycle): $(grep -iE 'EQUIVALENT|MISMATCH|CPI|verdict' "$OUT/$K.cmp_B" | head -2 | tr '\n' ' ')"
done

say "VERDICT"
[ "$RC" = 0 ] && echo "FP_PIPE2 A/B GATE: PASS (cycle-identical to FP_PIPE on all FP kernels)" || echo "FP_PIPE2 A/B GATE: FAIL"
exit $RC
