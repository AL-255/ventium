#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Iterative F2XM1 engine gate: assert fpu_f2xm1.sv is bit-exact vs the qemu-mode
# reference qref.c (itself proven == real qemu-i386). Vectors come from
# `qref --sweep` (193 inputs across every branch).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"; BUILD="$ROOT/build/trsc"; VERILATOR="${VERILATOR:-verilator}"
mkdir -p "$BUILD"

echo "=== F2XM1 gate: build qref ==="
make -C tools/p5xtrans qref >/dev/null

# Sweep all four x87 rounding modes (RNE / down / up / truncate). Each RC needs
# its own vectors (qref --sweep <rc>) AND its own TB build (+define+F2_RC).
PASS_ALL=1
for RC in 0 1 2 3; do
  tools/p5xtrans/qref --sweep "$RC" > "$BUILD/sweep_$RC.txt"
  awk '{print $1}' "$BUILD/sweep_$RC.txt" > "$BUILD/f2xm1_in.hex"
  awk '{print $2}' "$BUILD/sweep_$RC.txt" > "$BUILD/f2xm1_out.hex"
  N=$(wc -l < "$BUILD/sweep_$RC.txt")
  echo "=== F2XM1 gate: rc=$RC ($N vectors) — build + run ==="
  "$VERILATOR" --binary --timing --quiet -Wall -Wno-fatal \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME -Wno-IMPLICITSTATIC \
    +define+F2_NV="$N" +define+F2_RC="$RC" -Mdir "$BUILD/obj_$RC" --top-module tb_f2xm1 \
    -I"$ROOT/rtl/fpu" \
    rtl/fpu/fpu_x87_pkg.sv rtl/fpu/fpu_f2xm1.sv verif/trsc/tb_f2xm1.sv >/dev/null
  OUT="$("$BUILD/obj_$RC/Vtb_f2xm1")"; echo "$OUT" | grep -E "F2XM1-GATE"
  echo "$OUT" | grep -q "F2XM1-GATE-OK" || PASS_ALL=0
done
[ "$PASS_ALL" = "1" ] || { echo "F2XM1-GATE: FAIL"; exit 1; }
echo "F2XM1-GATE: PASS (all 4 rounding modes, bit-exact vs qref==qemu-i386)"
