#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Matching-ID orphan-B response containment.  The special macro suppresses only
# bresp_present_owned, the exact environment contract intentionally violated by
# this test; all delivery, queue-ownership, and AXI-stability assertions remain.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OBJ="${VENTIUM_BUILD_DIR:-$ROOT/build}/axi-orphan-b-contain"
mkdir -p "$OBJ"

CCACHE_DISABLE=1 "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" \
    --binary -sv --assert +define+VEN_AXI_FAULT_INJECT +define+VEN_AXI_B_ORPHAN_INJECT \
    -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-IMPLICITSTATIC \
    --top-module tb_axi_orphan_b_contain -Mdir "$OBJ/obj" -o tb_axi_orphan_b_contain \
    "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/verif/l1/tb_axi_orphan_b_contain.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "AXI-ORPHAN-B-CONTAIN-GATE-FAIL (build)"; tail -60 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/obj/tb_axi_orphan_b_contain" 2>&1)"
echo "$OUT"
grep -q 'AXI-ORPHAN-B-CONTAIN-GATE-OK' <<<"$OUT" \
    || { echo "AXI-ORPHAN-B-CONTAIN-GATE-FAIL"; exit 1; }
