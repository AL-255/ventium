#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ventium-alu-memory-decode.XXXXXX")"
echo "Artifacts: $OUT"
for top in tb_alu_memory_decode tb_decode_tail_invariance; do
  test_source="$ROOT/verif/issue_uv/$top.sv"
  if [[ "$top" == tb_decode_tail_invariance ]]; then
    test_source="$ROOT/verif/uopcache/$top.sv"
  fi
  "$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
    -Werror-LATCH -Werror-UNOPTFLAT +define+VEN_FAST_MEM_ADD \
    +define+VEN_FAST_MEM_ADD7 +define+VEN_FAST_MEM_ALU +define+VEN_FAST_MEM_MOV7 \
    --top-module "$top" -Mdir "$OUT/$top" \
    "$ROOT/rtl/ventium_pkg.sv" "$ROOT/rtl/core/ventium_alu_pkg.sv" \
    "$ROOT/rtl/core/ventium_decode_pkg.sv" "$ROOT/rtl/core/ventium_sys_pkg.sv" \
    "$ROOT/rtl/core/decode.sv" "$test_source" \
    > "$OUT/$top.build.log" 2>&1 || { tail -50 "$OUT/$top.build.log"; exit 1; }
  "$OUT/$top/V$top"
done
