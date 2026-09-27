#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# verif/l1/run-l1axi-cdc-dma-reset-gate.sh -- narrow CDC-reset/DMA-seam gate.
#
# Build the L1/AXI seam with BOTH optional paths that make this reset ordering
# observable: VEN_AXI_CDC supplies per-domain async-assert/sync-deassert reset
# bridges, and VEN_NB_DMA exposes the local requester.  The directed TB holds
# dma_req high through raw reset deassertion and requires nb_dma_req and
# dma_inflight to remain zero until the core-domain synchronized reset releases.
#
# This deliberately builds only the L1/AXI seam, not a whole-core Verilator TB.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

# Preserve UNOPTFLAT checking: a reset/CDC combinational loop is exactly the
# class this small directed gate is intended to keep visible.  The serial wrapper
# is mandatory on shared hosts; its default is one compile job.
"$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary -sv --assert \
    +define+VEN_AXI_CDC +define+VEN_NB_DMA \
    -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-IMPLICITSTATIC \
    --top-module tb_l1axi_cdc_dma_reset -Mdir "$OBJ" -o tb_l1axi_cdc_dma_reset \
    "$ROOT/rtl/mem/ven_cdc_afifo.sv" "$ROOT/rtl/mem/ven_reset_sync.sv" \
    "$ROOT/rtl/mem/ven_axi_cdc.sv" "$ROOT/rtl/mem/ven_l1d.sv" \
    "$ROOT/rtl/mem/ven_axi_master.sv" "$ROOT/rtl/northbridge/ven_cachemap.sv" \
    "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/verif/l1/tb_l1axi_cdc_dma_reset.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "L1AXICDCDMARESET-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1axi_cdc_dma_reset" 2>&1)"
echo "$OUT"
grep -q "L1AXICDCDMARESET-GATE-OK" <<<"$OUT" \
    || { echo "L1AXICDCDMARESET-GATE-FAIL"; exit 1; }
