#!/usr/bin/env bash
# verif/l1/run-l2-axi-gate.sh — end-to-end gate: ven_l2 ▸ the REAL ven_axi_master ▸
# axi_slave_bfm. Proves the L2's downstream backing-port master is a drop-in for
# ven_l1d's (production ven_axi_master accepts its fills as INCR8 bursts + its dirty
# writebacks as single-beat writes), tolerates real AXI latency + a mid-burst RVALID
# bubble, and that L2 hits / write-back suppress AXI traffic. Run from the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-CASEINCOMPLETE --top-module tb_l2_axi \
    -Mdir "$OBJ" -o tb_l2_axi \
    "$ROOT/rtl/mem/ven_l2.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/verif/l1/axi_slave_bfm.sv" "$ROOT/verif/l1/tb_l2_axi.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L2AXI-GATE-FAIL (build)"; tail -30 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l2_axi" 2>&1)"
echo "$OUT"
grep -q "L2AXI-GATE-OK" <<<"$OUT" || { echo "L2AXI-GATE-FAIL"; exit 1; }
echo "== L2+AXI gate PASS =="
