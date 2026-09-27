#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d /tmp/ventium-l1d-mem-chain.XXXXXX)"
# Keep artifacts for owner/data failures; parent runs this inside build_scope.
"$ROOT/tools/verilator_serial.sh" -j 1 --binary -sv --timescale 1ns/1ps -Wno-WIDTH -Wno-UNUSED \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -DVEN_PIPE_MEM_CHAIN \
    --top-module tb_l1d_mem_chain -Mdir "$OBJ" -o tb_l1d_mem_chain \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/tb_l1d_mem_chain.sv" \
    >"$OBJ/build.log" 2>&1 || { tail -50 "$OBJ/build.log"; exit 1; }
"$OBJ/tb_l1d_mem_chain" | tee "$OBJ/run.log"
rg -q L1D-MEM-CHAIN-OK "$OBJ/run.log"
