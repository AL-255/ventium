#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="$root"
. "$root/verif/lib/verilator_env.sh"
outbase="${P54_BENCH_OUTBASE:-/tmp}"
obj="$(mktemp -d "$outbase/p54-dual-issue.XXXXXXXX")"
echo "Artifacts: $obj"
SECONDS=0
for variant in control byte; do
  remaining=$((540 - SECONDS))
  (( remaining > 0 )) || { echo "nine-minute issue gate budget expired" >&2; exit 1; }
  defines=(+define+VTM_NO_DPI +define+VEN_P54_DUAL_LOAD_PAIR)
  if [[ "$variant" == byte ]]; then
    defines+=(+define+VEN_P54_DUAL_BYTE_LOAD_PAIR)
  fi
  timeout --signal=TERM --kill-after=10s "$remaining" \
    "$root/tools/verilator_serial.sh" --binary --assert -sv \
    "${defines[@]}" -Wno-WIDTH -Wno-UNUSED \
    -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
    --top-module tb_p54_dual_load_issue \
    -Mdir "$obj/$variant" -o tb_p54_dual_load_issue \
    "$root/rtl/ventium_pkg.sv" "$root/rtl/core/ventium_alu_pkg.sv" \
    "$root/rtl/core/ventium_decode_pkg.sv" "$root/rtl/core/decode.sv" \
    "$root/rtl/core/issue_uv.sv" \
    "$root/verif/bench/tb_p54_dual_load_issue.sv" > "$obj/$variant.build.log" 2>&1 \
    || { tail -40 "$obj/$variant.build.log"; exit 1; }
  timeout 20s "$obj/$variant/tb_p54_dual_load_issue"
done
