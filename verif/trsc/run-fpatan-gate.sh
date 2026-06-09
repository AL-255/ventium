#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Iterative FPATAN engine gate: assert fpu_fpatan.sv is bit-exact vs the qemu-mode
# reference qfpatan (itself proven == real qemu-i386). All 4 rounding modes.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"; BUILD="$ROOT/build/trsc"; VERILATOR="${VERILATOR:-verilator}"
mkdir -p "$BUILD"

echo "=== FPATAN gate: build qref ==="
make -C tools/p5xtrans qref >/dev/null

PASS_ALL=1
for RC in 0 1 2 3; do
  tools/p5xtrans/qref --sweep-fpatan "$RC" > "$BUILD/fpatan_$RC.txt"
  awk '{print $1}' "$BUILD/fpatan_$RC.txt" > "$BUILD/fpatan_y.hex"
  awk '{print $2}' "$BUILD/fpatan_$RC.txt" > "$BUILD/fpatan_x.hex"
  awk '{print $3}' "$BUILD/fpatan_$RC.txt" > "$BUILD/fpatan_o.hex"
  N=$(wc -l < "$BUILD/fpatan_$RC.txt")
  echo "=== FPATAN gate: rc=$RC ($N vectors) — build + run ==="
  "$VERILATOR" --binary --timing --quiet -Wall -Wno-fatal \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME -Wno-IMPLICITSTATIC \
    +define+FA_NV="$N" +define+FA_RC="$RC" -Mdir "$BUILD/objfa_$RC" --top-module tb_fpatan \
    -I"$ROOT/rtl/fpu" \
    rtl/fpu/fpu_x87_pkg.sv rtl/fpu/fpu_fpatan.sv verif/trsc/tb_fpatan.sv >/dev/null
  OUT="$("$BUILD/objfa_$RC/Vtb_fpatan")"; echo "$OUT" | grep -E "FPATAN-GATE"
  echo "$OUT" | grep -q "FPATAN-GATE-OK" || PASS_ALL=0
done
[ "$PASS_ALL" = "1" ] || { echo "FPATAN-GATE: FAIL"; exit 1; }
echo "FPATAN-GATE: PASS (all 4 rounding modes, bit-exact vs qref==qemu-i386)"
