#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Deliberately inject a non-OKAY AXI RRESP into a cache-fill's delivered burst,
# early and final cache-fill priming beats, an ordinary narrow read, and the
# sole priming beat of a NARROW_REPLAY_SAFE narrow read.  The narrow
# VEN_AXI_RESP_FAULT_INJECT define suppresses only the deliberate response-
# status assumptions, so this gate retains all unrelated assertions.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

CCACHE_DISABLE=1 "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" \
    --binary -sv --assert +define+VEN_AXI_RESP_FAULT_INJECT -Wno-UNUSED -Wno-DECLFILENAME \
    --top-module tb_axi_rresp_contain -Mdir "$OBJ/obj" -o tb_axi_rresp_contain \
    "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/verif/l1/tb_axi_rresp_contain.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "AXI-RRESP-CONTAIN-GATE-FAIL (build)"; tail -60 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/obj/tb_axi_rresp_contain" 2>&1)"
echo "$OUT"
grep -q 'AXI-RRESP-CONTAIN-GATE-OK' <<<"$OUT" \
    || { echo "AXI-RRESP-CONTAIN-GATE-FAIL"; exit 1; }
for tag in cache-line priming priming-final narrow narrow-replay-safe; do
    grep -Fq "AXI-RRESP-CONTAIN-CASE-OK [$tag]" <<<"$OUT" \
        || { echo "AXI-RRESP-CONTAIN-GATE-FAIL (missing case: $tag)"; exit 1; }
done
