#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Iterative integer divider gate: assert ven_idiv (rtl/core/ven_idiv.sv) is
# bit-exact (quotient/remainder/#DE) vs the native '/'/'%' + per-width overflow
# predicates core_exec.svh uses, over all six forms (DIV/IDIV x r8/r16/r32).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"; BUILD="$ROOT/build/idiv"; VERILATOR="${VERILATOR:-verilator}"
N="${IDIV_N:-80000}"
echo "=== IDIV gate: build Verilator TB (ven_idiv, --timing) ==="
"$VERILATOR" --binary --timing --quiet -Wall -Wno-fatal \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME -Wno-IMPLICITSTATIC \
  +define+IDIV_N="$N" -Mdir "$BUILD/obj" --top-module tb_idiv \
  rtl/core/ven_idiv.sv verif/idiv/tb_idiv.sv >/dev/null
echo "=== IDIV gate: run ==="
OUT="$("$BUILD/obj/Vtb_idiv")"; echo "$OUT"
echo "$OUT" | grep -q "IDIV-GATE-OK" || { echo "IDIV-GATE: FAIL"; exit 1; }
echo "IDIV-GATE: PASS"
