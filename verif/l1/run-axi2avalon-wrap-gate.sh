#!/usr/bin/env bash
# AXI WRAP8 critical-word ordering through the ao486 Avalon compatibility seam.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-axi2avalon-wrap.XXXXXX")"
trap 'rm -rf "$OBJ"' EXIT
EXTRA=()
if [[ "${STREAM_ANY:-0}" == 1 && ( "${REAL_L2:-0}" != 1 || "${STREAM_L2:-0}" != 1 ) ]]; then
  echo "STREAM_ANY requires REAL_L2=1 STREAM_L2=1"; exit 2
fi
if [[ "${REAL_L2:-0}" == 1 ]]; then
  EXTRA+=(-DVEN_BRIDGE_REAL_L2 -Wno-fatal -Wno-WIDTH -Wno-PINMISSING -Wno-PINCONNECTEMPTY
    "$ROOT/3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v"
    "$ROOT/ao486-sim/stubs/sim_prims.sv")
  if [[ "${STREAM_L2:-0}" == 1 ]]; then EXTRA+=(-DVEN_L2_STREAM_CWF); fi
  if [[ "${STREAM_ANY:-0}" == 1 ]]; then
    EXTRA+=(-DVEN_L2_STREAM_ANY)
  fi
fi
"$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary -sv --assert \
  -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
  --top-module tb_axi2avalon -Mdir "$OBJ" -o tb_axi2avalon \
  "$ROOT/ao486-sim/ven/ven_axi2avalon.sv" "$ROOT/ao486-sim/ven/tb_axi2avalon.sv" \
  "${EXTRA[@]}" \
  > "$OBJ/build.log" 2>&1 \
  || { echo "AXI2AVALON-WRAP-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }
OUT="$("$OBJ/tb_axi2avalon" 2>&1)" || {
  echo "$OUT"
  echo "AXI2AVALON-WRAP-GATE-FAIL (simulation)"
  exit 1
}
echo "$OUT"
grep -q "AXI2AVALON-WRAP-GATE-OK" <<<"$OUT" || { echo "AXI2AVALON-WRAP-GATE-FAIL"; exit 1; }
echo "== AXI2AVALON WRAP gate PASS =="
