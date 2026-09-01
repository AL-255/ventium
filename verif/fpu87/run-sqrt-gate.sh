#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-sqrt-gate.sh — STANDALONE OOC gate for FSQRT on the iterative SRT engine
# (rtl/fpu/fpu_srt_div.sv mode=1), bit-exact vs the SoftFloat sqrt golden. Reuses
# the divider tb (tb_srt_div.cpp) in sqrt mode. Quake uses sqrt heavily (vector
# lengths), so this is a prime suspect for the upstream op feeding the bad fist.
#
# Usage:  bash verif/fpu87/run-sqrt-gate.sh [count] [seed]
# Env:    N, SEED; KEEP=1 to keep the build dir; TMPDIR for g++ temp (real disk).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COUNT="${1:-${N:-8000}}"
SEED="${2:-${SEED:-1234}}"
ORACLE="$HERE/build/ven_fpu_oracle"
OBJ="$HERE/obj_srtdiv"          # same module as the divider gate
VEC="$HERE/build/sqrt_vectors.txt"
. "$ROOT/verif/lib/verilator_env.sh"
VL_J="${VL_J:-1}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "1) build SoftFloat oracle"
mkdir -p "$HERE/build"
make -C "$HERE" oracle > "$HERE/build/sqrt_oracle_build.log" 2>&1 \
    || { tail -15 "$HERE/build/sqrt_oracle_build.log"; die "oracle build failed"; }

say "2) Verilate fpu_srt_div OOC (reuse if already built)"
if [ ! -x "$OBJ/tb_srt_div" ]; then
  mkdir -p "$OBJ"
  "$VERILATOR" --cc --exe --build -j "$VL_J" -O3 -Wno-fatal \
      -Mdir "$OBJ" --top-module fpu_srt_div \
      "$ROOT/rtl/fpu/fpu_x87_pkg.sv" "$ROOT/rtl/fpu/fpu_srt_div.sv" \
      "$HERE/tb_srt_div.cpp" -o tb_srt_div \
      > "$HERE/build/sqrt_verilate.log" 2>&1 \
      || { tail -30 "$HERE/build/sqrt_verilate.log"; die "verilate/build failed"; }
fi
[ -x "$OBJ/tb_srt_div" ] || die "tb_srt_div not built"

say "3) generate $COUNT sqrt vectors (seed $SEED) + golden"
python3 "$HERE/gen_sqrt_vectors.py" "$ORACLE" "$VEC" "$COUNT" "$SEED" || die "vector generation failed"

say "4) run the sqrt OOC gate"
"$OBJ/tb_srt_div" "$VEC" sqrt
RC=$?

[ "${KEEP:-0}" = 1 ] || rm -rf "$OBJ"
exit $RC
