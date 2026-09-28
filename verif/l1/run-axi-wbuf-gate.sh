#!/usr/bin/env bash
# verif/l1/run-axi-wbuf-gate.sh — P54C write-buffer capacity/order regression.
# Exercises ven_axi_master against a pipelined-B test slave that holds write
# responses long enough to prove exactly two bounded P5 buffers and a hard
# read-after-write drain.  The ordinary L1AXI gate covers data-array integration;
# this one owns the AXI posting/ordering contract directly.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
extra=()
if [[ "${1:-}" == "--pair" && $# == 1 ]]; then
    extra=(+define+VEN_P54_DUAL_STORE_PAIR)
elif [[ "${1:-}" == "--pair-alias" && $# == 1 ]]; then
    extra=(+define+VEN_P54_DUAL_STORE_PAIR +define+VEN_P54_PAIR_ALIAS_TEST)
elif [[ "${1:-}" == "--pair-error" && $# == 1 ]]; then
    extra=(+define+VEN_P54_DUAL_STORE_PAIR +define+VEN_P54_PAIR_ERROR_TEST
           +define+VEN_AXI_RESP_FAULT_INJECT)
elif [[ $# != 0 ]]; then
    echo "usage: $0 [--pair|--pair-alias|--pair-error]" >&2
    exit 2
fi
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-axi-wbuf.XXXXXX")"
trap 'rm -rf "$OBJ"' EXIT

"$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary -sv --assert -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC "${extra[@]}" --top-module tb_axi_wbuf -Mdir "$OBJ" -o tb_axi_wbuf \
    "$ROOT/rtl/mem/ven_axi_master.sv" "$ROOT/verif/l1/tb_axi_wbuf.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "AXIWBUF-GATE-FAIL (build)"; tail -35 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_axi_wbuf" 2>&1)"
echo "$OUT"
if [[ "${1:-}" == "--pair-alias" ]]; then
    marker=AXIWBUF-PAIR-ALIAS-GATE-OK
elif [[ "${1:-}" == "--pair-error" ]]; then
    marker=AXIWBUF-PAIR-ERROR-GATE-OK
else
    marker=AXIWBUF-GATE-OK
fi
grep -q "$marker" <<<"$OUT" || { echo "AXIWBUF-GATE-FAIL"; exit 1; }
echo "== AXI P54C write-buffer gate PASS =="
