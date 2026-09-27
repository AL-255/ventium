#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-mem-chain-policy.XXXXXX")"
ok=0
trap 'if [[ "$ok" == 1 ]]; then rm -rf -- "$OBJ"; else echo "Artifacts: $OBJ"; fi' EXIT
run_one() {
  local label="$1"; shift
  local dir="$OBJ/$label"
  mkdir "$dir"
  "$ROOT/tools/verilator_serial.sh" --binary -j 1 --assert -sv \
    -DVEN_PIPE_MEM_CHAIN -DVEN_UOPCACHE -DVEN_L1_AXI \
    -DVEN_SYS_FASTLOAD_FLAT -DVEN_SYS_FASTLOAD_BOUNDED \
    -Wno-WIDTH -Wno-UNUSED -Wno-TIMESCALEMOD \
    "$@" +incdir+"$ROOT/rtl/core" --top-module tb_mem_chain_policy \
    -Mdir "$dir" -o tb_mem_chain_policy \
    "$ROOT/rtl/core/ventium_decode_pkg.sv" "$ROOT/rtl/core/issue_uv.sv" \
    "$ROOT/verif/issue_uv/tb_mem_chain_policy.sv" >"$dir/build.log" 2>&1 \
    || { tail -50 "$dir/build.log"; return 1; }
  "$dir/tb_mem_chain_policy" | tee "$dir/run.log"
  rg -q MEM-CHAIN-POLICY-OK "$dir/run.log"
}
run_one baseline
run_one register_prime -DVEN_PIPE_REG_LOAD_PRIME
ok=1
