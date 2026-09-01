#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-fxdiv-gate.sh — STANDALONE OOC gate for the BEHAVIORAL x87 divide
# fpu_x87_pkg::fx_div (the f_arith FDIV path), checked bit-exact vs the SoftFloat-3e
# extF80 oracle. fx_div routes DENORMAL-operand divides to fx_div_exact — the path
# whose board-fit stub (q=num>>7) was restored to the real 192-bit divide in 66a71c4
# — and gen_div_vectors.py emits ~18%/operand denormals, so ~1/3 of vectors exercise
# it. Verilates ONLY fpu_x87_pkg + the wrapper (small, fast, low memory; no full core).
#
# Usage:  bash verif/fpu87/run-fxdiv-gate.sh [count] [seed]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COUNT="${1:-${N:-8000}}"
SEED="${2:-${SEED:-1234}}"
ORACLE="$HERE/build/ven_fpu_oracle"
OBJ="$HERE/obj_fxdiv"
VEC="$HERE/build/fxdiv_vectors.txt"
. "$ROOT/verif/lib/verilator_env.sh"
VL_J="${VL_J:-1}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "1) build SoftFloat oracle"
make -C "$HERE" oracle > "$HERE/build/fxdiv_oracle.log" 2>&1 \
    || { tail -15 "$HERE/build/fxdiv_oracle.log"; die "oracle build failed"; }
[ -x "$ORACLE" ] || die "oracle missing: $ORACLE"

say "2) Verilate fx_div OOC (package + wrapper only)"
mkdir -p "$OBJ"
"$VERILATOR" --cc --exe --build -j "$VL_J" -O3 -Wno-fatal \
    -Mdir "$OBJ" --top-module fxdiv_dut \
    "$ROOT/rtl/fpu/fpu_x87_pkg.sv" "$HERE/fxdiv_dut.sv" "$HERE/tb_fxdiv.cpp" -o tb_fxdiv \
    > "$HERE/build/fxdiv_verilate.log" 2>&1 \
    || { tail -30 "$HERE/build/fxdiv_verilate.log"; die "verilate/build failed"; }
[ -x "$OBJ/tb_fxdiv" ] || die "tb_fxdiv not built"

say "3) generate $COUNT divide vectors (seed $SEED) + oracle golden"
python3 "$HERE/gen_div_vectors.py" "$ORACLE" "$VEC" "$COUNT" "$SEED" \
    || die "vector generation failed"

say "4) run the fx_div OOC gate"
"$OBJ/tb_fxdiv" "$VEC"
RC=$?

[ "${KEEP:-0}" = 1 ] || rm -rf "$OBJ"
exit $RC
