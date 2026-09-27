#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Focused +VEN_AXI_CDC RRESP-fatal containment gate.  The testbench deliberately
# injects one legal-shape SLVERR response, so --no-assert is required only here:
# ven_axi_master's rresp_okay assertion correctly rejects this stimulus in every
# ordinary build.  Keep the serial/cgroup build wrapper and UNOPTFLAT checking.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

"$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary -sv --no-assert \
    +define+VEN_AXI_CDC \
    -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-IMPLICITSTATIC \
    --top-module tb_l1axi_cdc_rresp -Mdir "$OBJ" -o tb_l1axi_cdc_rresp \
    "$ROOT/rtl/mem/ven_cdc_afifo.sv" "$ROOT/rtl/mem/ven_reset_sync.sv" \
    "$ROOT/rtl/mem/ven_axi_cdc.sv" "$ROOT/rtl/mem/ven_l1d.sv" \
    "$ROOT/rtl/mem/ven_axi_master.sv" "$ROOT/rtl/northbridge/ven_cachemap.sv" \
    "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/verif/l1/tb_l1axi_cdc_rresp.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "L1AXICDCRRESP-GATE-FAIL (build)"; tail -60 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1axi_cdc_rresp" 2>&1)"
echo "$OUT"
grep -q "L1AXICDCRRESP-GATE-OK" <<<"$OUT" \
    || { echo "L1AXICDCRRESP-GATE-FAIL"; exit 1; }
