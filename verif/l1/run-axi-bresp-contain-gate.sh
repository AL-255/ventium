#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Deliberately inject one non-OKAY AXI BRESP while a second store is held at
# ven_axi_master's backing port.  The narrow VEN_AXI_RESP_FAULT_INJECT define
# suppresses only the deliberate response-status assumptions, so this gate
# retains all unrelated assertions.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

CCACHE_DISABLE=1 "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" \
    --binary -sv --assert +define+VEN_AXI_RESP_FAULT_INJECT -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC --top-module tb_axi_bresp_contain \
    -Mdir "$OBJ/obj" -o tb_axi_bresp_contain \
    "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/verif/l1/tb_axi_bresp_contain.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "AXI-BRESP-CONTAIN-GATE-FAIL (build)"; tail -60 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/obj/tb_axi_bresp_contain" 2>&1)"
echo "$OUT"
grep -q 'AXI-BRESP-CONTAIN-GATE-OK' <<<"$OUT" \
    || { echo "AXI-BRESP-CONTAIN-GATE-FAIL"; exit 1; }
