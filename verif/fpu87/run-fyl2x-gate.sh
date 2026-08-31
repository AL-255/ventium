#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-fyl2x-gate.sh — STANDALONE OOC CHARACTERIZATION of FYL2X (fpu_fyl2x.sv)
# vs the qref P5 transcendental oracle. Quantifies the known divergence (count +
# ULP magnitude) to judge Quake-relevance. Verilates only fpu_fyl2x + its ROMs.
#
# Usage:  bash verif/fpu87/run-fyl2x-gate.sh [count] [seed]
# Env:    KEEP=1; TMPDIR for g++ temp (real disk).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COUNT="${1:-2000}"
SEED="${2:-1234}"
QREF="$ROOT/tools/p5xtrans/qref"
OBJ="$HERE/obj_fyl2x"
VEC="$HERE/build/fyl2x_vectors.txt"
VERILATOR="${VERILATOR:-verilator}"
VL_J="${VL_J:-1}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ -x "$QREF" ] || die "qref not built: $QREF"
mkdir -p "$HERE/build"

say "1) Verilate fpu_fyl2x OOC (module + ROMs; -I rtl/fpu)"
mkdir -p "$OBJ"
"$VERILATOR" --cc --exe --build -j "$VL_J" -O3 -Wno-fatal -I"$ROOT/rtl/fpu" \
    -Mdir "$OBJ" --top-module fpu_fyl2x \
    "$ROOT/rtl/fpu/fpu_x87_pkg.sv" "$ROOT/rtl/fpu/fpu_fyl2x.sv" \
    "$HERE/tb_fyl2x.cpp" -o tb_fyl2x \
    > "$HERE/build/fyl2x_verilate.log" 2>&1 \
    || { tail -30 "$HERE/build/fyl2x_verilate.log"; die "verilate/build failed"; }
[ -x "$OBJ/tb_fyl2x" ] || die "tb_fyl2x not built"

say "2) generate $COUNT fyl2x vectors (seed $SEED) + qref golden"
python3 "$HERE/gen_fyl2x_vectors.py" "$QREF" "$VEC" "$COUNT" "$SEED" || die "vector generation failed"

say "3) characterize FYL2X vs qref"
"$OBJ/tb_fyl2x" "$VEC"
RC=$?
[ "${KEEP:-0}" = 1 ] || rm -rf "$OBJ"
exit $RC
