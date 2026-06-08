#!/usr/bin/env bash
# verif/decpipe/run-fplen-gate.sh — +VEN_DEC_PIPE step-1 gate: prove the length-only
# sub-decoder ventium_decode_pkg::fp_len is a bit-identical projection of
# decode.sv's fp_decode .len over all (b0,b1,cycle_mode). Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT
verilator --binary -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC +define+VTM_NO_DPI --top-module tb_fplen -Mdir "$OBJ" -o tb_fplen \
    "$ROOT/rtl/ventium_pkg.sv" "$ROOT/rtl/core/ventium_alu_pkg.sv" \
    "$ROOT/rtl/core/ventium_decode_pkg.sv" "$ROOT/rtl/core/decode.sv" \
    "$ROOT/verif/decpipe/tb_fplen.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "FPLEN-GATE-FAIL (build)"; tail -20 "$OBJ/build.log"; exit 1; }
OUT="$("$OBJ/tb_fplen" 2>&1)"; echo "$OUT"
grep -q "FPLEN-GATE-OK" <<<"$OUT" || { echo "FPLEN-GATE-FAIL"; exit 1; }
echo "== fp_len gate PASS =="
