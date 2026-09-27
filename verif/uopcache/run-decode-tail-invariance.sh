#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ventium-decode-tail.XXXXXX")"
echo "Artifacts: $OUT"
"$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
  -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
  -Werror-LATCH -Werror-UNOPTFLAT +define+VEN_FP_SHARED +define+VEN_FP_SHARED_DIRECT \
  +define+VEN_FP_MEM_ADMIT +define+VEN_FP_MEM_LOADS \
  +define+VEN_FAST_MEM_ADD +define+VEN_FAST_MEM_ADD7 +define+VEN_FAST_MEM_ADC \
  +define+VEN_FAST_MEM_MOV7 --top-module tb_decode_tail_invariance -Mdir "$OUT" \
  "$ROOT/rtl/ventium_pkg.sv" "$ROOT/rtl/core/ventium_alu_pkg.sv" \
  "$ROOT/rtl/core/ventium_decode_pkg.sv" "$ROOT/rtl/core/ventium_sys_pkg.sv" \
  "$ROOT/rtl/core/decode.sv" "$ROOT/verif/uopcache/tb_decode_tail_invariance.sv" \
  > "$OUT/build.log" 2>&1 || { tail -50 "$OUT/build.log"; exit 1; }
"$OUT/Vtb_decode_tail_invariance"
