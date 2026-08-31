#!/usr/bin/env bash
# verif/l1/run-axi-wbuf-gate.sh — P54C write-buffer capacity/order regression.
# Exercises ven_axi_master against a pipelined-B test slave that holds write
# responses long enough to prove exactly two bounded P5 buffers and a hard
# read-after-write drain.  The ordinary L1AXI gate covers data-array integration;
# this one owns the AXI posting/ordering contract directly.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary -sv --assert -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC --top-module tb_axi_wbuf -Mdir "$OBJ" -o tb_axi_wbuf \
    "$ROOT/rtl/mem/ven_axi_master.sv" "$ROOT/verif/l1/tb_axi_wbuf.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "AXIWBUF-GATE-FAIL (build)"; tail -35 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_axi_wbuf" 2>&1)"
echo "$OUT"
grep -q "AXIWBUF-GATE-OK" <<<"$OUT" || { echo "AXIWBUF-GATE-FAIL"; exit 1; }
echo "== AXI P54C write-buffer gate PASS =="
