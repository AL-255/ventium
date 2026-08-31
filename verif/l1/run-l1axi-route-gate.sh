#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-l1axi-route-gate.sh — REVIEW1_Aug3 R2-H02/R2-H03/R2-H12 unit gate.
# Builds tb_l1axi_route (six harnesses: extent classification, the no-L2
# router with a memory hole enabled, CR0.CD=1 no-allocation, the windowed
# R_PCI contract x2, and the PAM window boundary -- each with byte/word
# endpoint cases at its policy boundaries, reads and writes) and asserts
# L1AXIROUTE-GATE-OK. Same build discipline as run-l1axi-narrow-gate.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator -j "${VL_J:-1}" --binary -sv --assert +define+AXI_BFM_MON \
    -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-IMPLICITSTATIC \
    --top-module tb_l1axi_route -Mdir "$OBJ" -o tb_l1axi_route \
    "$ROOT/rtl/mem/ven_cdc_afifo.sv" "$ROOT/rtl/mem/ven_reset_sync.sv" \
    "$ROOT/rtl/mem/ven_axi_cdc.sv" "$ROOT/rtl/mem/ven_l1d.sv" \
    "$ROOT/rtl/mem/ven_axi_master.sv" "$ROOT/rtl/northbridge/ven_cachemap.sv" \
    "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/verif/l1/axi_slave_bfm.sv" "$ROOT/verif/l1/tb_l1axi_route.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "L1AXIROUTE-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1axi_route" 2>&1)"
echo "$OUT"
grep -q "L1AXIROUTE-GATE-OK" <<<"$OUT" || { echo "L1AXIROUTE-GATE-FAIL"; exit 1; }
echo "== L1AXI route/extent/CD gate PASS =="
