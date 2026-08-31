#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-feval-gate.sh — STANDALONE OOC gate for the x87 add/sub/mul/subr evaluator
# (ventium_x87_pkg::f_eval + the board split f_eval_s2(f_eval_s1)), bit-exact vs
# the SoftFloat extF80 oracle, AND split==full. Verilates only the two packages +
# wrapper (tiny, low memory). Hunts the upstream op feeding the bad Quake fist.
#
# Usage:  bash verif/fpu87/run-feval-gate.sh [count] [seed]
# Env:    N, SEED; KEEP=1 to keep the build dir.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COUNT="${1:-${N:-20000}}"
SEED="${2:-${SEED:-1234}}"
ORACLE="$HERE/build/ven_fpu_oracle"
OBJ="$HERE/obj_feval"
VEC="$HERE/build/feval_vectors.txt"
VERILATOR="${VERILATOR:-verilator}"
VL_J="${VL_J:-1}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "1) build SoftFloat oracle"
mkdir -p "$HERE/build"
make -C "$HERE" oracle > "$HERE/build/feval_oracle_build.log" 2>&1 \
    || { tail -15 "$HERE/build/feval_oracle_build.log"; die "oracle build failed"; }
[ -x "$ORACLE" ] || die "oracle missing: $ORACLE"

say "2) Verilate feval_dut OOC (packages + wrapper only)"
mkdir -p "$OBJ"
"$VERILATOR" --cc --exe --build -j "$VL_J" -O3 -Wno-fatal \
    -Mdir "$OBJ" --top-module feval_dut \
    "$ROOT/rtl/fpu/fpu_x87_pkg.sv" "$ROOT/rtl/core/ventium_x87_pkg.sv" \
    "$HERE/feval_dut.sv" "$HERE/tb_feval.cpp" -o tb_feval \
    > "$HERE/build/feval_verilate.log" 2>&1 \
    || { tail -30 "$HERE/build/feval_verilate.log"; die "verilate/build failed"; }
[ -x "$OBJ/tb_feval" ] || die "tb_feval not built"

say "3) generate $COUNT add/sub/mul vectors (seed $SEED) + golden"
python3 "$HERE/gen_feval_vectors.py" "$ORACLE" "$VEC" "$COUNT" "$SEED" \
    || die "vector generation failed"

say "4) run the f_eval OOC gate"
"$OBJ/tb_feval" "$VEC"
RC=$?

[ "${KEEP:-0}" = 1 ] || rm -rf "$OBJ"
exit $RC
