#!/usr/bin/env bash
# verif/l1/run-tlb-gate.sh — standalone unit gate for rtl/mem/tlb.sv (the direct-
# mapped I/D-TLB array). Builds the self-checking tb_tlb with Verilator --binary and
# asserts TLB-GATE-OK: diverse fills/lookups/flushes exercise the entry arrays +
# lookup datapath (core-internal module otherwise only hit via the ISA/sys lanes).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT
"$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD --top-module tb_tlb -Mdir "$OBJ" -o tb_tlb \
    "$ROOT/rtl/mem/tlb.sv" "$ROOT/verif/l1/tb_tlb.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "TLB-GATE-FAIL (build)"; tail -30 "$OBJ/build.log"; exit 1; }
OUT="$("$OBJ/tb_tlb" 2>&1)"; echo "$OUT"
grep -q "TLB-GATE-OK" <<<"$OUT" || { echo "TLB-GATE-FAIL"; exit 1; }
echo "== TLB gate PASS =="
