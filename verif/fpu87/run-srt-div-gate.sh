#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-srt-div-gate.sh — STANDALONE out-of-context gate for the iterative SRT
# divider (rtl/fpu/fpu_srt_div.sv) in divide mode, checked bit-exact vs the
# SoftFloat-3e extF80 oracle.
#
# This Verilates ONLY fpu_srt_div + fpu_x87_pkg (small, fast, low memory) — it
# does NOT build the full core, so it is safe on resource-tight boxes where the
# full fpu87 / make-verify path exhausts memory. It tests the engine that
# actually ships on the board (the combinational divider is only reachable in
# the default full-core build, which never sees +VEN_SRT_ITER).
#
# Usage:  bash verif/fpu87/run-srt-div-gate.sh [count] [seed]
# Env:    N, SEED (override args); KEEP=1 to keep build dirs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
COUNT="${1:-${N:-4000}}"
SEED="${2:-${SEED:-1234}}"
ORACLE="$HERE/build/ven_fpu_oracle"
OBJ="$HERE/obj_srtdiv"
VEC="$HERE/build/div_vectors.txt"
. "$ROOT/verif/lib/verilator_env.sh"
VL_J="${VL_J:-1}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "1) build SoftFloat oracle"
make -C "$HERE" oracle > "$HERE/build/srtdiv_oracle.log" 2>&1 \
    || { tail -15 "$HERE/build/srtdiv_oracle.log"; die "oracle build failed"; }
[ -x "$ORACLE" ] || die "oracle missing: $ORACLE"

say "2) Verilate fpu_srt_div OOC (divider + package only)"
mkdir -p "$OBJ"
"$VERILATOR" --cc --exe --build -j "$VL_J" -O3 -Wno-fatal \
    -Mdir "$OBJ" --top-module fpu_srt_div \
    "$ROOT/rtl/fpu/fpu_x87_pkg.sv" "$ROOT/rtl/fpu/fpu_srt_div.sv" \
    "$HERE/tb_srt_div.cpp" -o tb_srt_div \
    > "$HERE/build/srtdiv_verilate.log" 2>&1 \
    || { tail -30 "$HERE/build/srtdiv_verilate.log"; die "verilate/build failed"; }
[ -x "$OBJ/tb_srt_div" ] || die "tb_srt_div not built"

say "3) generate $COUNT divide vectors (seed $SEED) + oracle golden"
python3 "$HERE/gen_div_vectors.py" "$ORACLE" "$VEC" "$COUNT" "$SEED" \
    || die "vector generation failed"

say "4) run the divider OOC gate"
"$OBJ/tb_srt_div" "$VEC"
RC=$?

[ "${KEEP:-0}" = 1 ] || rm -rf "$OBJ"
exit $RC
