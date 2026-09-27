#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Default (no-VEN_AXI_CDC) asymmetric AXI-reset regression.  Keep it separate
# from the CDC reset gates: their coupled synchronizers already exercise a
# different reset implementation and cannot prove the deployed bypass wiring.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

"$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary -sv --assert \
    -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-IMPLICITSTATIC \
    --top-module tb_l1axi_bypass_reset -Mdir "$OBJ" -o tb_l1axi_bypass_reset \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/verif/l1/tb_l1axi_bypass_reset.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "L1AXIBYPASSRESET-GATE-FAIL (build)"; tail -60 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1axi_bypass_reset" 2>&1)"
echo "$OUT"
grep -q "L1AXIBYPASSRESET-GATE-OK" <<<"$OUT" \
    || { echo "L1AXIBYPASSRESET-GATE-FAIL"; exit 1; }
