#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-fist-gate.sh — STANDALONE OOC gate for the x87 FIST/FISTP conversion
# (fpu_x87_pkg::fx_to_int_ex), bit-exact vs the SoftFloat fist golden. Verilates
# only fist_dut + the package (tiny, low memory) — safe on resource-tight boxes.
# This is the pinned board-F5 suspect (DOS-Quake live-loop fist @0x3079a).
#
# Usage:  bash verif/fpu87/run-fist-gate.sh [count] [seed]
# Env:    N, SEED; KEEP=1 to keep the build dir.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COUNT="${1:-${N:-24000}}"
SEED="${2:-${SEED:-1234}}"
FIST_ORACLE="$HERE/build/fist_oracle"
OBJ="$HERE/obj_fist"
VEC="$HERE/build/fist_vectors.txt"
VERILATOR="${VERILATOR:-verilator}"
VL_J="${VL_J:-1}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "1) build SoftFloat fist golden"
mkdir -p "$HERE/build"
make -C "$HERE" fist > "$HERE/build/fist_oracle_build.log" 2>&1 \
    || { tail -15 "$HERE/build/fist_oracle_build.log"; die "fist oracle build failed"; }
[ -x "$FIST_ORACLE" ] || die "fist oracle missing: $FIST_ORACLE"

say "2) Verilate fist_dut OOC (package + wrapper only)"
mkdir -p "$OBJ"
"$VERILATOR" --cc --exe --build -j "$VL_J" -O3 -Wno-fatal \
    -Mdir "$OBJ" --top-module fist_dut \
    "$ROOT/rtl/fpu/fpu_x87_pkg.sv" "$HERE/fist_dut.sv" \
    "$HERE/tb_fist.cpp" -o tb_fist \
    > "$HERE/build/fist_verilate.log" 2>&1 \
    || { tail -30 "$HERE/build/fist_verilate.log"; die "verilate/build failed"; }
[ -x "$OBJ/tb_fist" ] || die "tb_fist not built"

say "3) generate $COUNT fist vectors (seed $SEED) + golden"
python3 "$HERE/gen_fist_vectors.py" "$FIST_ORACLE" "$VEC" "$COUNT" "$SEED" \
    || die "vector generation failed"

say "4) run the fist OOC gate"
"$OBJ/tb_fist" "$VEC"
RC=$?

[ "${KEEP:-0}" = 1 ] || rm -rf "$OBJ"
exit $RC
