#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Direct response-ownership containment check.  The test intentionally violates
# the normal-build ownership assertions, so it defines VEN_AXI_FAULT_INJECT to
# suppress only those intentional environmental assumptions while retaining
# VALID-stability and all containment assertions.  RAR is the matching-ID
# response presented before AR ownership.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OBJ="${VENTIUM_BUILD_DIR:-$ROOT/build}/axi-id-contain"
mkdir -p "$OBJ"

CCACHE_DISABLE=1 "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" \
    --binary -sv --assert +define+VEN_AXI_FAULT_INJECT -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC --top-module tb_axi_id_contain \
    -Mdir "$OBJ/obj" -o tb_axi_id_contain \
    "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/verif/l1/tb_axi_id_contain.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "AXI-ID-CONTAIN-GATE-FAIL (build)"; tail -60 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/obj/tb_axi_id_contain" 2>&1)"
echo "$OUT"
grep -q 'AXI-ID-CONTAIN-GATE-OK' <<<"$OUT" \
    || { echo "AXI-ID-CONTAIN-GATE-FAIL"; exit 1; }
for tag in RID RAR BID; do
    grep -Fq "AXI-ID-CONTAIN-CASE-OK [$tag]" <<<"$OUT" \
        || { echo "AXI-ID-CONTAIN-GATE-FAIL (missing case: $tag)"; exit 1; }
done
