#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-conv-gate.sh — STANDALONE OOC gate for the x87 f32/f64 <-> floatx80
# conversions (FLD/FST m32/m64 = fx_from_f32/f64 + fx_to_f32_ex/f64_ex), bit-exact
# vs the SoftFloat conv golden. Verilates only fpu_x87_pkg + the wrapper.
#
# Usage:  bash verif/fpu87/run-conv-gate.sh [count] [seed]
# Env:    N, SEED; KEEP=1 to keep build dir; TMPDIR for g++ temp (use real disk).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COUNT="${1:-${N:-24000}}"
SEED="${2:-${SEED:-1234}}"
CONV_ORACLE="$HERE/build/conv_oracle"
OBJ="$HERE/obj_conv"
VEC="$HERE/build/conv_vectors.txt"
VERILATOR="${VERILATOR:-verilator}"
VL_J="${VL_J:-1}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "1) build SoftFloat conv golden"
mkdir -p "$HERE/build"
make -C "$HERE" conv > "$HERE/build/conv_oracle_build.log" 2>&1 \
    || { tail -15 "$HERE/build/conv_oracle_build.log"; die "conv oracle build failed"; }
[ -x "$CONV_ORACLE" ] || die "conv oracle missing: $CONV_ORACLE"

say "2) Verilate conv_dut OOC (package + wrapper only)"
mkdir -p "$OBJ"
"$VERILATOR" --cc --exe --build -j "$VL_J" -O3 -Wno-fatal \
    -Mdir "$OBJ" --top-module conv_dut \
    "$ROOT/rtl/fpu/fpu_x87_pkg.sv" "$HERE/conv_dut.sv" "$HERE/tb_conv.cpp" -o tb_conv \
    > "$HERE/build/conv_verilate.log" 2>&1 \
    || { tail -30 "$HERE/build/conv_verilate.log"; die "verilate/build failed"; }
[ -x "$OBJ/tb_conv" ] || die "tb_conv not built"

say "3) generate $COUNT conversion vectors (seed $SEED) + golden"
python3 "$HERE/gen_conv_vectors.py" "$CONV_ORACLE" "$VEC" "$COUNT" "$SEED" || die "vector generation failed"

say "4) run the conversion OOC gate"
"$OBJ/tb_conv" "$VEC"
RC=$?

[ "${KEEP:-0}" = 1 ] || rm -rf "$OBJ"
exit $RC
