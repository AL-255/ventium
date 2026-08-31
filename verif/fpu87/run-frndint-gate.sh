#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-frndint-gate.sh — STANDALONE OOC gate for x87 FRNDINT (frndint_dut, a
# faithful extract of fpu_writeback.sv's FRNDINT path), bit-exact vs the SoftFloat
# round-to-int golden. Also confirms the fx_to_int_ex fist fix propagates here.
#
# Usage:  bash verif/fpu87/run-frndint-gate.sh [count] [seed]
# Env:    N, SEED; KEEP=1; TMPDIR for g++ temp (real disk).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COUNT="${1:-${N:-24000}}"
SEED="${2:-${SEED:-1234}}"
ORACLE="$HERE/build/ven_fpu_oracle"
OBJ="$HERE/obj_frndint"
VEC="$HERE/build/frndint_vectors.txt"
VERILATOR="${VERILATOR:-verilator}"
VL_J="${VL_J:-1}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "1) build SoftFloat oracle"
mkdir -p "$HERE/build"
make -C "$HERE" oracle > "$HERE/build/frndint_oracle_build.log" 2>&1 \
    || { tail -15 "$HERE/build/frndint_oracle_build.log"; die "oracle build failed"; }

say "2) Verilate frndint_dut OOC (package + wrapper)"
mkdir -p "$OBJ"
"$VERILATOR" --cc --exe --build -j "$VL_J" -O3 -Wno-fatal \
    -Mdir "$OBJ" --top-module frndint_dut \
    "$ROOT/rtl/fpu/fpu_x87_pkg.sv" "$HERE/frndint_dut.sv" "$HERE/tb_frndint.cpp" -o tb_frndint \
    > "$HERE/build/frndint_verilate.log" 2>&1 \
    || { tail -30 "$HERE/build/frndint_verilate.log"; die "verilate/build failed"; }
[ -x "$OBJ/tb_frndint" ] || die "tb_frndint not built"

say "3) generate $COUNT frndint vectors (seed $SEED) + golden"
python3 "$HERE/gen_frndint_vectors.py" "$ORACLE" "$VEC" "$COUNT" "$SEED" || die "vector generation failed"

say "4) run the FRNDINT OOC gate"
"$OBJ/tb_frndint" "$VEC"
RC=$?
[ "${KEEP:-0}" = 1 ] || rm -rf "$OBJ"
exit $RC
