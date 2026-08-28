#!/usr/bin/env bash
# Decoder + pairing proof for ESP RAW handling.  Kept standalone so it fails
# before a full corpus rebuild can hide a scheduler regression behind slow-path
# execution.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT

CCACHE_DISABLE=1 verilator --binary --assert -sv +define+VTM_NO_DPI \
  -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
  -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD \
  --top-module tb_issue_uv -Mdir "$OBJ" -o tb_issue_uv \
  "$ROOT/rtl/ventium_pkg.sv" \
  "$ROOT/rtl/core/ventium_alu_pkg.sv" \
  "$ROOT/rtl/core/ventium_decode_pkg.sv" \
  "$ROOT/rtl/core/decode.sv" \
  "$ROOT/rtl/core/issue_uv.sv" \
  "$ROOT/verif/issue_uv/tb_issue_uv.sv" > "$OBJ/build.log" 2>&1 \
  || { echo "ISSUE-UV-GATE-FAIL (build)"; tail -30 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_issue_uv" 2>&1)"; echo "$OUT"
grep -q "ISSUE-UV-GATE-OK" <<<"$OUT" || { echo "ISSUE-UV-GATE-FAIL"; exit 1; }
