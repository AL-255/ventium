#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ventium-uop-crossline.XXXXXX")"
echo "Artifacts: $OUT"
extra=()
case "${CROSS_ENTRIES:-1}" in
  1) ;;
  2) extra+=(+define+VEN_UOP_CROSS2) ;;
  33) extra+=(+define+VEN_UOP_CROSS2 +define+VEN_UOP_CROSS_INDEX) ;;
  *) echo 'CROSS_ENTRIES must be 1, 2, or 33 (primary + indexed victims)' >&2; exit 2 ;;
esac
case "${UOP_FAIR:-0}" in
  0) ;;
  1) extra+=(+define+VEN_UOP_REPAIR_FAIR) ;;
  *) echo 'UOP_FAIR must be 0 or 1' >&2; exit 2 ;;
esac
"$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
  -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
  -Werror-LATCH -Werror-UNOPTFLAT +define+VEN_UOP_CROSSLINE "${extra[@]}" \
  +define+VEN_FAST_MEM_ADD +define+VEN_FAST_MEM_ADD7 +define+VEN_FAST_MEM_ADC \
  --top-module tb_uopcache_crossline -Mdir "$OUT" \
  "$ROOT/rtl/ventium_pkg.sv" "$ROOT/rtl/core/ventium_alu_pkg.sv" \
  "$ROOT/rtl/core/ventium_decode_pkg.sv" "$ROOT/rtl/core/ventium_sys_pkg.sv" \
  "$ROOT/rtl/core/decode.sv" "$ROOT/rtl/mem/ven_predecode_len.sv" \
  "$ROOT/rtl/mem/uopcache.sv" "$ROOT/verif/uopcache/tb_uopcache_crossline.sv" \
  > "$OUT/build.log" 2>&1 || { tail -50 "$OUT/build.log"; exit 1; }
"$OUT/Vtb_uopcache_crossline"
if [[ "${CROSS_ENTRIES:-1}" == 33 ]]; then
  bash "$ROOT/verif/uopcache/run-decode-tail-invariance.sh"
fi
