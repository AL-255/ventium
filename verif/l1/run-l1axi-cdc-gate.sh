#!/usr/bin/env bash
# verif/l1/run-l1axi-cdc-gate.sh — P1-3 dual-clock CDC gate for ventium_l1_axi.
# Builds tb_l1axi_cdc with +VEN_AXI_CDC (the ven_axi_cdc bridge + two ven_cdc_afifo +
# the reset synchronizers) and runs the read-fill / write-through / evict scenarios at
# four core:axi clock ratios. Asserts L1AXICDC-GATE-OK (data coherent + no hang across
# the crossing). Run from the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

# NO blanket -Wno-WIDTH (keep the remap-truncation class visible). UNOPTFLAT would
# flag a CDC comb loop — leave it ON so a regression in the afifo is caught at build.
verilator --binary -sv --assert +define+VEN_AXI_CDC \
    -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-IMPLICITSTATIC \
    --top-module tb_l1axi_cdc -Mdir "$OBJ" -o tb_l1axi_cdc \
    "$ROOT/rtl/mem/ven_cdc_afifo.sv" "$ROOT/rtl/mem/ven_reset_sync.sv" \
    "$ROOT/rtl/mem/ven_axi_cdc.sv" "$ROOT/rtl/mem/ven_l1d.sv" \
    "$ROOT/rtl/mem/ven_axi_master.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/verif/l1/axi_slave_bfm.sv" "$ROOT/verif/l1/tb_l1axi_cdc.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "L1AXICDC-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1axi_cdc" 2>&1)"
echo "$OUT"
grep -q "L1AXICDC-GATE-OK" <<<"$OUT" || { echo "L1AXICDC-GATE-FAIL"; exit 1; }
echo "== L1AXI dual-clock CDC gate PASS =="
