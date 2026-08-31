#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-fcom-gate.sh — STANDALONE OOC gate for x87 FCOM condition codes
# (ventium_x87_pkg::fcom_codes) vs an independent floatx80 rational compare.
# No oracle needed (golden computed in Python). Verilates only the two packages
# + wrapper.
#
# Usage:  bash verif/fpu87/run-fcom-gate.sh [count] [seed]
# Env:    N, SEED; KEEP=1 to keep build dir; TMPDIR for g++ temp (real disk).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COUNT="${1:-${N:-30000}}"
SEED="${2:-${SEED:-1234}}"
OBJ="$HERE/obj_fcom"
VEC="$HERE/build/fcom_vectors.txt"
VERILATOR="${VERILATOR:-verilator}"
VL_J="${VL_J:-1}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "1) Verilate fcom_dut OOC (packages + wrapper only)"
mkdir -p "$HERE/build" "$OBJ"
"$VERILATOR" --cc --exe --build -j "$VL_J" -O3 -Wno-fatal \
    -Mdir "$OBJ" --top-module fcom_dut \
    "$ROOT/rtl/fpu/fpu_x87_pkg.sv" "$ROOT/rtl/core/ventium_x87_pkg.sv" \
    "$HERE/fcom_dut.sv" "$HERE/tb_fcom.cpp" -o tb_fcom \
    > "$HERE/build/fcom_verilate.log" 2>&1 \
    || { tail -30 "$HERE/build/fcom_verilate.log"; die "verilate/build failed"; }
[ -x "$OBJ/tb_fcom" ] || die "tb_fcom not built"

say "2) generate $COUNT fcom vectors (seed $SEED) + independent golden"
python3 "$HERE/gen_fcom_vectors.py" "$VEC" "$COUNT" "$SEED" || die "vector generation failed"

say "3) run the FCOM OOC gate"
"$OBJ/tb_fcom" "$VEC"
RC=$?

[ "${KEEP:-0}" = 1 ] || rm -rf "$OBJ"
exit $RC
