#!/usr/bin/env bash
# verif/l1/run-btb-gate.sh — standalone unit gate for rtl/core/bpred_btb.sv (the
# 64-set x 4-way branch-target buffer). Builds the self-checking tb_btb with
# Verilator --binary and asserts BTB-GATE-OK: diverse-tag allocations + counter
# saturation + dual-port queries exercise the entry arrays + lookup datapath.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT
verilator -j "${VL_J:-1}" --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD --top-module tb_btb -Mdir "$OBJ" -o tb_btb \
    "$ROOT/rtl/core/bpred_btb.sv" "$ROOT/verif/l1/tb_btb.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "BTB-GATE-FAIL (build)"; tail -30 "$OBJ/build.log"; exit 1; }
OUT="$("$OBJ/tb_btb" 2>&1)"; echo "$OUT"
grep -q "BTB-GATE-OK" <<<"$OUT" || { echo "BTB-GATE-FAIL"; exit 1; }
echo "== BTB gate PASS =="
