#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Iterative radix-4 SRT divider gate: reuse the single-source golden vectors and
# assert the multi-cycle engine (rtl/fpu/fpu_srt_div.sv) is bit-exact vs the
# golden for BOTH PLAs (== the proven combinational fx_srt_div == QEMU).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"; BUILD="$ROOT/build/srt"; VERILATOR="${VERILATOR:-verilator}"
echo "=== SRT-iter gate: generate golden vectors (tools/srt/srt_model.py) ==="
N="$(python3 verif/srt/gen_vectors.py "$BUILD")"
echo "    wrote $N vectors -> $BUILD"
echo "=== SRT-iter gate: build Verilator TB (fpu_srt_div, --timing) ==="
"$VERILATOR" --binary --timing --quiet -Wall -Wno-fatal \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME \
  +define+SRT_N="$N" -Mdir "$BUILD/obj_iter" --top-module tb_srt_iter \
  rtl/fpu/fpu_x87_pkg.sv rtl/fpu/fpu_srt_div.sv verif/srt/tb_srt_iter.sv >/dev/null
echo "=== SRT-iter gate: run ==="
OUT="$("$BUILD/obj_iter/Vtb_srt_iter")"; echo "$OUT"
echo "$OUT" | grep -q "SRT-ITER-GATE-OK" || { echo "SRT-ITER-GATE: FAIL"; exit 1; }
echo "SRT-ITER-GATE: PASS"
