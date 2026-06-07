#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Iterative packed-BCD -> floatx80 (FBLD) engine gate: assert ven_bcd_to_fp is
# bit-exact vs the combinational fx_bcd_to_fx over random valid packed-BCD.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"; BUILD="$ROOT/build/fbld"; VERILATOR="${VERILATOR:-verilator}"
N="${FBLD_N:-40000}"
echo "=== FBLD gate: build Verilator TB (ven_bcd_to_fp, --timing) ==="
"$VERILATOR" --binary --timing --quiet -Wall -Wno-fatal \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME -Wno-IMPLICITSTATIC \
  +define+FBLD_N="$N" -Mdir "$BUILD/obj" --top-module tb_bcd_to_fp \
  rtl/fpu/fpu_x87_pkg.sv rtl/fpu/ven_bcd_to_fp.sv verif/fbld/tb_bcd_to_fp.sv >/dev/null
echo "=== FBLD gate: run ==="
OUT="$("$BUILD/obj/Vtb_bcd_to_fp")"; echo "$OUT"
echo "$OUT" | grep -q "FBLD-GATE-OK" || { echo "FBLD-GATE: FAIL"; exit 1; }
echo "FBLD-GATE: PASS"
