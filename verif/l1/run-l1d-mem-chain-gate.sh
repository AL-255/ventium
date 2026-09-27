#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-l1d-mem-chain.XXXXXX")"
# Keep artifacts for owner/data failures; discard successful scratch builds.
ok=0
trap 'if [[ "$ok" == 1 ]]; then rm -rf -- "$OBJ"; else echo "Artifacts: $OBJ"; fi' EXIT
run_one() {
    local label="$1"; shift
    local dir="$OBJ/$label"
    mkdir "$dir"
    "$ROOT/tools/verilator_serial.sh" -j 1 --binary -sv --timescale 1ns/1ps -Wno-WIDTH -Wno-UNUSED \
        -Wno-INITIALDLY -Wno-IMPLICITSTATIC -DVEN_PIPE_MEM_CHAIN -DVEN_L1D_PERF \
        "$@" --top-module tb_l1d_mem_chain -Mdir "$dir" -o tb_l1d_mem_chain \
        "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/tb_l1d_mem_chain.sv" \
        >"$dir/build.log" 2>&1 || { tail -50 "$dir/build.log"; return 1; }
    "$dir/tb_l1d_mem_chain" | tee "$dir/run.log"
    rg -q L1D-MEM-CHAIN-OK "$dir/run.log"
}
run_one baseline
# Exercise the exact L1 policy conjunction used by the full-PC candidate with
# the already-enabled registered next-read chain, including selective store
# invalidation. This checks response ownership where the two options meet.
run_one cache_policy -DVEN_L1D_HIT_UNDER_FILL -DVEN_L1D_FILL_FORWARD \
    -DVEN_L1D_WINDOW_REUSE -DVEN_L1D_WINDOW_KEEP_STORE -DVEN_L1D_TAG_INVALIDATE \
    -DVEN_FP_LOAD64 -DVEN_L1_HONOR_CD
ok=1
