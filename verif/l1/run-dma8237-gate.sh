#!/usr/bin/env bash
# verif/l1/run-dma8237-gate.sh — Phase D.3 gate: the 8237 DMA transfer engine
# (ven_i8237_dma) driving the northbridge's coherent DMA requester end-to-end. Builds
# tb_dma8237 (engine → ventium_l1_axi.dma_* EN_L2=1 → DDR) and asserts DMA8237-GATE-OK:
# a device→mem transfer writes the device pattern into memory (CPU read sees it, coherent);
# a mem→device transfer reads a seeded block into the device. Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    +define+VEN_NB_DMA \
    --top-module tb_dma8237 -Mdir "$OBJ" -o tb_dma8237 \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/rtl/northbridge/ven_l2.sv" \
    "$ROOT/rtl/northbridge/ven_northbridge.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/rtl/soc/ven_i8237_dma.sv" \
    "$ROOT/verif/l1/axi_slave_bfm.sv" "$ROOT/verif/l1/tb_dma8237.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "DMA8237-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_dma8237" 2>&1)"
echo "$OUT"
grep -q "DMA8237-GATE-OK" <<<"$OUT" || { echo "DMA8237-GATE-FAIL"; exit 1; }
echo "== 8237 DMA transfer-engine gate PASS =="
