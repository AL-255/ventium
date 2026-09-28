#!/usr/bin/env bash
# Focused, bounded banked-L1 U/V store microtest; no full-system verification.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-l1d-pair-store.XXXXXX")"
trap 'rm -rf "$OBJ"' EXIT
EXTRA=()
if [[ "${WINDOW_KEEP:-0}" == basic ]]; then
    EXTRA+=(+define+VEN_L1D_WINDOW_REUSE +define+VEN_L1D_WINDOW_KEEP_STORE)
elif [[ "${WINDOW_KEEP:-0}" == 1 ]]; then
    EXTRA+=(+define+VEN_L1D_WINDOW_REUSE +define+VEN_L1D_WINDOW_KEEP_STORE
            +define+VEN_L1D_TWO_WINDOW_REUSE +define+VEN_L1D_TWO_WINDOW_KEEP_STORE)
elif [[ "${WINDOW_KEEP:-0}" != 0 ]]; then
    echo "WINDOW_KEEP must be 0, basic or 1" >&2; exit 2
fi
if [[ "${LOAD_STORE:-0}" == 1 ]]; then
    EXTRA+=(+define+VEN_P54_LOAD_STORE_PAIR)
elif [[ "${LOAD_STORE:-0}" != 0 ]]; then
    echo "LOAD_STORE must be 0 or 1" >&2; exit 2
fi
timeout 300s "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary -sv --assert \
    -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-IMPLICITSTATIC \
    +define+VEN_L1D_BANKED_DATA +define+VEN_P54_DUAL_STORE_PAIR \
    "${EXTRA[@]}" \
    --top-module tb_l1d_pair_store -Mdir "$OBJ" -o tb_l1d_pair_store \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/tb_l1d_pair_store.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "L1D-PAIR-STORE-GATE-FAIL (build)"; tail -35 "$OBJ/build.log"; exit 1; }
OUT="$(timeout 60s "$OBJ/tb_l1d_pair_store" 2>&1)"
echo "$OUT"
grep -q 'L1D-PAIR-STORE-GATE-OK' <<<"$OUT" || { echo "L1D-PAIR-STORE-GATE-FAIL"; exit 1; }
