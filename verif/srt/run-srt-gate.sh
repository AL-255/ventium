#!/usr/bin/env bash
# Radix-4 SRT divider gate: regenerate golden vectors from the single-source
# model, build the Verilator TB against the real fpu_x87_pkg, run, assert OK.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"; BUILD="$ROOT/build/srt"; VERILATOR="${VERILATOR:-verilator}"
echo "=== SRT gate: generate golden vectors (tools/srt/srt_model.py) ==="
N="$(python3 verif/srt/gen_vectors.py "$BUILD")"
echo "    wrote $N vectors -> $BUILD"
echo "=== SRT gate: build Verilator TB (fx_srt_div) ==="
"$VERILATOR" --binary --quiet -Wall -Wno-fatal \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME \
  +define+SRT_N="$N" -Mdir "$BUILD/obj" --top-module tb_srt \
  rtl/fpu/fpu_x87_pkg.sv verif/srt/tb_srt.sv >/dev/null
echo "=== SRT gate: run ==="
OUT="$("$BUILD/obj/Vtb_srt")"; echo "$OUT"
echo "$OUT" | grep -q "SRT-GATE-OK" || { echo "SRT-GATE: FAIL"; exit 1; }
echo "SRT-GATE: PASS"
