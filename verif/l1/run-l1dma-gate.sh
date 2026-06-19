#!/usr/bin/env bash
# verif/l1/run-l1dma-gate.sh — Phase D coherence gate: the northbridge keeps the CPU L1
# coherent with a DMA bus master (ventium_l1_axi EN_L2=1, +VEN_NB_DMA). Builds the
# self-checking tb_l1dma with Verilator --binary and asserts L1DMA-GATE-OK: a DMA write
# snoop-invalidates the stale L1 copy (CPU re-read sees the new value; DDR still holds the
# old value, proving write-back); a DMA read sees CPU-dirtied L2 data; an uncacheable DMA
# write bypasses to DDR; the CPU/DMA arbiter interleaves correctly. Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    +define+VEN_NB_DMA +define+VEN_DBG_CORE +define+VEN_DBG_L2 \
    --top-module tb_l1dma -Mdir "$OBJ" -o tb_l1dma \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/rtl/northbridge/ven_l2.sv" \
    "$ROOT/rtl/northbridge/ven_northbridge.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/verif/l1/axi_slave_bfm.sv" "$ROOT/verif/l1/tb_l1dma.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L1DMA-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1dma" 2>&1)"
echo "$OUT"
grep -q "L1DMA-GATE-OK" <<<"$OUT" || { echo "L1DMA-GATE-FAIL"; exit 1; }
echo "== northbridge DMA-coherence gate PASS =="
