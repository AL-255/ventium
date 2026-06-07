#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# 2-stage FP arithmetic split gate: assert f_eval_s2(f_eval_s1(...)) is bit-exact
# vs the single-cycle f_eval over the add/sub/mul groups + all rounding modes +
# normal/zero/Inf/NaN operands. Proves the +VEN_FP_PIPE datapath split is exact.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"; BUILD="$ROOT/build/fppipe"; VERILATOR="${VERILATOR:-verilator}"
N="${FPPIPE_N:-1000000}"
echo "=== FP-pipe split gate: build Verilator TB ==="
"$VERILATOR" --binary --quiet -Wall -Wno-fatal \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME -Wno-IMPLICITSTATIC \
  +define+FPPIPE_N="$N" -Mdir "$BUILD/obj" --top-module tb_fppipe \
  rtl/ventium_pkg.sv rtl/core/ventium_alu_pkg.sv rtl/core/ventium_decode_pkg.sv \
  rtl/fpu/fpu_x87_pkg.sv rtl/core/ventium_sys_pkg.sv rtl/core/ventium_x87_pkg.sv \
  verif/fppipe/tb_fppipe.sv >/dev/null
echo "=== FP-pipe split gate: run ($N vectors) ==="
OUT="$("$BUILD/obj/Vtb_fppipe")"; echo "$OUT"
echo "$OUT" | grep -q "FPPIPE-GATE-OK" || { echo "FPPIPE-GATE: FAIL"; exit 1; }
echo "FPPIPE-GATE: PASS"
