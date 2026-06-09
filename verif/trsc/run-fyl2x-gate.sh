#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Iterative FYL2X/FYL2XP1 engine gate: fpu_fyl2x bit-exact vs qref (== qemu-i386),
# both ops x all 4 rounding modes.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"; BUILD="$ROOT/build/trsc"; VERILATOR="${VERILATOR:-verilator}"
mkdir -p "$BUILD"
echo "=== FYL2X gate: build qref ==="
make -C tools/p5xtrans qref >/dev/null

PASS_ALL=1
for SPEC in "0:--sweep-fyl2x:FYL2X" "1:--sweep-fyl2xp1:FYL2XP1"; do
  MODE="${SPEC%%:*}"; rest="${SPEC#*:}"; FLAG="${rest%%:*}"; NAME="${rest##*:}"
  for RC in 0 1 2 3; do
    tools/p5xtrans/qref "$FLAG" "$RC" > "$BUILD/fyl2x_$RC.txt"
    awk '{print $1}' "$BUILD/fyl2x_$RC.txt" > "$BUILD/fyl2x_y.hex"
    awk '{print $2}' "$BUILD/fyl2x_$RC.txt" > "$BUILD/fyl2x_x.hex"
    awk '{print $3}' "$BUILD/fyl2x_$RC.txt" > "$BUILD/fyl2x_o.hex"
    N=$(wc -l < "$BUILD/fyl2x_$RC.txt")
    echo "=== $NAME gate: mode=$MODE rc=$RC ($N vectors) ==="
    "$VERILATOR" --binary --timing --quiet -Wall -Wno-fatal \
      -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME -Wno-IMPLICITSTATIC \
      +define+FY_NV="$N" +define+FY_RC="$RC" +define+FY_MODE="$MODE" \
      -Mdir "$BUILD/objfy_${MODE}_$RC" --top-module tb_fyl2x -I"$ROOT/rtl/fpu" \
      rtl/fpu/fpu_x87_pkg.sv rtl/fpu/fpu_fyl2x.sv verif/trsc/tb_fyl2x.sv >/dev/null
    OUT="$("$BUILD/objfy_${MODE}_$RC/Vtb_fyl2x")"; echo "$OUT" | grep -E "FYL2X-GATE"
    echo "$OUT" | grep -q "FYL2X-GATE-OK" || PASS_ALL=0
  done
done
[ "$PASS_ALL" = "1" ] || { echo "FYL2X-GATE: FAIL"; exit 1; }
echo "FYL2X-GATE: PASS (FYL2X + FYL2XP1, all 4 rounding modes, bit-exact vs qref==qemu-i386)"
