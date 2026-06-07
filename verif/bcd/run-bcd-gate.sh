#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Iterative FP->packed-BCD (FBSTP) engine gate: assert ven_bcd (rtl/fpu/ven_bcd.sv)
# is bit-exact ({ie,pe,bcd}) vs the combinational fx_fx_to_bcd over random floatx80
# values spanning the BCD range + the int64/range overflow cases.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"; BUILD="$ROOT/build/bcd"; VERILATOR="${VERILATOR:-verilator}"
N="${BCD_N:-40000}"
echo "=== BCD gate: build Verilator TB (ven_bcd, --timing) ==="
"$VERILATOR" --binary --timing --quiet -Wall -Wno-fatal \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME -Wno-IMPLICITSTATIC \
  +define+BCD_N="$N" -Mdir "$BUILD/obj" --top-module tb_bcd \
  rtl/fpu/fpu_x87_pkg.sv rtl/fpu/ven_bcd.sv verif/bcd/tb_bcd.sv >/dev/null
echo "=== BCD gate: run ==="
OUT="$("$BUILD/obj/Vtb_bcd")"; echo "$OUT"
echo "$OUT" | grep -q "BCD-GATE-OK" || { echo "BCD-GATE: FAIL"; exit 1; }
echo "BCD-GATE: PASS"
