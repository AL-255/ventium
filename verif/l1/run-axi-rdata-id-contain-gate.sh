#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Wrong-RID containment after AR ownership.  The fault-injection define masks
# only the deliberately violated ID/ownership environment assumptions; all
# data-delivery, error-containment, and AXI-stability assertions stay enabled.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OBJ="${VENTIUM_BUILD_DIR:-$ROOT/build}/axi-rdata-id-contain"
mkdir -p "$OBJ"

CCACHE_DISABLE=1 "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" \
    --binary -sv --assert +define+VEN_AXI_FAULT_INJECT -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC --top-module tb_axi_rdata_id_contain \
    -Mdir "$OBJ/obj" -o tb_axi_rdata_id_contain \
    "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/verif/l1/tb_axi_rdata_id_contain.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "AXI-RDATA-ID-CONTAIN-GATE-FAIL (build)"; tail -60 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/obj/tb_axi_rdata_id_contain" 2>&1)"
echo "$OUT"
grep -q 'AXI-RDATA-ID-CONTAIN-GATE-OK' <<<"$OUT" \
    || { echo "AXI-RDATA-ID-CONTAIN-GATE-FAIL"; exit 1; }
