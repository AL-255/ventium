#!/usr/bin/env bash
# Decoder + pairing proof for ESP RAW handling.  Kept standalone so it fails
# before a full corpus rebuild can hide a scheduler regression behind slow-path
# execution.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/verif/lib/verilator_env.sh"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT

# Keep this self-contained gate safe to invoke from `make verify` on shared
# hosts.  Verilator otherwise chooses its host-wide default compiler fan-out;
# this tiny decoder proof has no throughput need for that.  Callers may still
# explicitly request a different bounded value through VL_J.
VL_J="${VL_J:-1}"
extra_defines=()
if [[ "${MEMORY_ADC:-0}" == 1 ]]; then
  extra_defines+=(+define+VEN_FAST_MEM_ADC)
fi
if [[ "${DUAL_READ_ALU:-0}" == 1 ]]; then
  extra_defines+=(+define+VEN_FAST_MEM_ADC +define+VEN_FAST_MEM_ALU
                  +define+VEN_P54_DUAL_LOAD_PAIR +define+VEN_P54_DUAL_READ_ALU_PAIR)
fi
if [[ "${LOAD_USE_FORWARD:-0}" == 1 ]]; then
  extra_defines+=(+define+VEN_LOAD_USE_FORWARD +define+VEN_PERF_PROFILE)
fi
CCACHE_DISABLE=1 verilator --binary -j "$VL_J" --assert -sv +define+VTM_NO_DPI \
  "${extra_defines[@]}" \
  +define+VEN_FAST_MEM_ADD +define+VEN_FAST_MEM_ADD7 \
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

if ! OUT="$("$OBJ/tb_issue_uv" 2>&1)"; then
  echo "$OUT"
  echo "ISSUE-UV-GATE-FAIL (simulation)"
  exit 1
fi
echo "$OUT"
grep -q "ISSUE-UV-GATE-OK" <<<"$OUT" || { echo "ISSUE-UV-GATE-FAIL"; exit 1; }
