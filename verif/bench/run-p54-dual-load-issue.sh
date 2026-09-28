#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="$root"
. "$root/verif/lib/verilator_env.sh"
mkdir -p "$root/tmp/build-tmp"
obj="$(mktemp -d -p "$root/tmp/build-tmp" p54-dual-issue.XXXXXXXX)"
trap 'rm -rf "$obj"' EXIT
timeout 120s verilator --binary -j 2 --assert -sv +define+VTM_NO_DPI \
  +define+VEN_P54_DUAL_LOAD_PAIR -Wno-WIDTH -Wno-UNUSED \
  -Wno-DECLFILENAME -Wno-TIMESCALEMOD --top-module tb_p54_dual_load_issue \
  -Mdir "$obj" -o tb_p54_dual_load_issue \
  "$root/rtl/ventium_pkg.sv" "$root/rtl/core/ventium_alu_pkg.sv" \
  "$root/rtl/core/ventium_decode_pkg.sv" "$root/rtl/core/decode.sv" \
  "$root/rtl/core/issue_uv.sv" \
  "$root/verif/bench/tb_p54_dual_load_issue.sv" > "$obj/build.log" 2>&1 \
  || { tail -40 "$obj/build.log"; exit 1; }
"$obj/tb_p54_dual_load_issue"
