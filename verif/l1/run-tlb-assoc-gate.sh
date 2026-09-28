#!/usr/bin/env bash
# verif/l1/run-tlb-assoc-gate.sh -- reference-model unit gate for the default-off
# D-TLB associativity experiment.  Builds and runs both 16-set x 2-way and
# 16-set x 4-way instances; the normal direct-map TLB gate remains separate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-tlb-assoc.XXXXXX")"; trap 'rm -rf "$OBJ"' EXIT

for ways in 2 4; do
    exe="tb_tlb_assoc_${ways}way"
    log="$OBJ/${exe}.log"
    "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary --assert -sv \
        -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
        -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD --top-module tb_tlb_assoc \
        -GWAYS="$ways" -Mdir "$OBJ/$exe" -o "$exe" \
        "$ROOT/rtl/mem/tlb_assoc.sv" "$ROOT/verif/l1/tb_tlb_assoc.sv" \
        >"$log" 2>&1 \
        || { echo "TLB-ASSOC-GATE-FAIL (${ways}-way build)"; tail -30 "$log"; exit 1; }
    OUT="$("$OBJ/$exe/$exe" 2>&1)"; echo "$OUT"
    grep -q "TLB-ASSOC-GATE-OK (${ways}-way)" <<<"$OUT" \
        || { echo "TLB-ASSOC-GATE-FAIL (${ways}-way run)"; exit 1; }
done
echo "== associative TLB gate PASS (2-way + 4-way) =="
