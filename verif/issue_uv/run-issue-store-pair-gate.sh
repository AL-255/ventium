#!/usr/bin/env bash
# Bounded U/V store-classification microtest, not a full verification gate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-issue-store-pair.XXXXXX")"
trap 'rm -rf "$OBJ"' EXIT
timeout 300s "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary -sv --assert \
    -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD \
    +define+VTM_NO_DPI +define+VEN_P54_DUAL_STORE_PAIR \
    --top-module tb_issue_store_pair -Mdir "$OBJ" -o tb_issue_store_pair \
    "$ROOT/rtl/ventium_pkg.sv" "$ROOT/rtl/core/ventium_alu_pkg.sv" \
    "$ROOT/rtl/core/ventium_decode_pkg.sv" "$ROOT/rtl/core/decode.sv" \
    "$ROOT/rtl/core/issue_uv.sv" "$ROOT/verif/issue_uv/tb_issue_store_pair.sv" \
    > "$OBJ/build.log" 2>&1 \
    || { echo "ISSUE-STORE-PAIR-GATE-FAIL (build)"; tail -35 "$OBJ/build.log"; exit 1; }
OUT="$(timeout 60s "$OBJ/tb_issue_store_pair" 2>&1)"
echo "$OUT"
grep -q 'ISSUE-STORE-PAIR-GATE-OK' <<<"$OUT" || { echo "ISSUE-STORE-PAIR-GATE-FAIL"; exit 1; }
