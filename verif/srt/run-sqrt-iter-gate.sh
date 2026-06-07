#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Iterative sqrt engine gate: assert the multi-cycle engine (rtl/fpu/
# fpu_sqrt_iter.sv) is bit-exact (full {inexact, floatx80}) vs the combinational
# fx_sqrt (== QEMU) over a random normal-operand corpus x 4 rounding modes.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"; BUILD="$ROOT/build/srt"; VERILATOR="${VERILATOR:-verilator}"
N="${SQRT_N:-8000}"
echo "=== SQRT-iter gate: build Verilator TB (fpu_sqrt_iter, --timing) ==="
"$VERILATOR" --binary --timing --quiet -Wall -Wno-fatal \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME \
  +define+SQRT_N="$N" -Mdir "$BUILD/obj_sqrt" --top-module tb_sqrt_iter \
  rtl/fpu/fpu_x87_pkg.sv rtl/fpu/fpu_sqrt_iter.sv verif/srt/tb_sqrt_iter.sv >/dev/null
echo "=== SQRT-iter gate: run ==="
OUT="$("$BUILD/obj_sqrt/Vtb_sqrt_iter")"; echo "$OUT"
echo "$OUT" | grep -q "SQRT-ITER-GATE-OK" || { echo "SQRT-ITER-GATE: FAIL"; exit 1; }
echo "SQRT-ITER-GATE: PASS"
