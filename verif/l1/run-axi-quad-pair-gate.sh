#!/usr/bin/env bash
# P54 two-write-buffer quadword fusion: one free slot, one 2-beat AXI burst,
# one B response, and read-after-write drain.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-axi-quad.XXXXXX")"
trap 'rm -rf "$OBJ"' EXIT
extra=()
marker=AXI-QUAD-PAIR-GATE-OK
if [[ "${1:-}" == "--error" && $# == 1 ]]; then
    extra=(+define+VEN_AXI_QUAD_BRESP_ERROR +define+VEN_AXI_RESP_FAULT_INJECT)
    marker=AXI-QUAD-PAIR-ERROR-GATE-OK
elif [[ "${1:-}" == "--split" && $# == 1 ]]; then
    extra=(+define+VEN_AXI_QUAD_SPLIT_TEST)
    marker=AXI-QUAD-SPLIT-GATE-OK
elif [[ $# != 0 ]]; then
    echo "usage: $0 [--error|--split]" >&2; exit 2
fi
"$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary -sv --assert \
    -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    +define+VEN_P54_DUAL_STORE_PAIR +define+VEN_P54_WBUF_QUAD_COMBINE "${extra[@]}" \
    --top-module tb_axi_quad_pair -Mdir "$OBJ" -o tb_axi_quad_pair \
    "$ROOT/rtl/mem/ven_axi_master.sv" "$ROOT/verif/l1/tb_axi_quad_pair.sv" \
    > "$OBJ/build.log" 2>&1 || { tail -50 "$OBJ/build.log"; exit 1; }
OUT="$("$OBJ/tb_axi_quad_pair" 2>&1)" || { echo "$OUT"; exit 1; }
echo "$OUT" | grep "$marker"
