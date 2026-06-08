#!/usr/bin/env bash
# verif/l1/run-l1axi-gate.sh — end-to-end gate for the L1+AXI subsystem (P1-1 step
# 2/3): ven_l1d + ven_axi_master (ventium_l1_axi) against a behavioral multi-cycle
# AXI4 DDR slave. Builds the self-checking tb_l1_axi with Verilator --binary and
# asserts L1AXI-GATE-OK (cold miss -> INCR8 burst fill, whole-line fill, write-
# through to DDR, 2-way LRU eviction, store-miss->dependent-load ordering, and the
# x86-phys -> DDR-carveout remap end-to-end). Run from the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

# NOTE: deliberately NO blanket -Wno-WIDTH — that would mask a remap-adder
# truncation class. Targeted lint_off WIDTH lives in the RTL on known-safe nets.
verilator --binary -sv --assert -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC --top-module tb_l1_axi -Mdir "$OBJ" -o tb_l1_axi \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/mem/ventium_l1_axi.sv" "$ROOT/verif/l1/axi_slave_bfm.sv" \
    "$ROOT/verif/l1/tb_l1_axi.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L1AXI-GATE-FAIL (build)"; tail -30 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1_axi" 2>&1)"
echo "$OUT"
grep -q "L1AXI-GATE-OK" <<<"$OUT" || { echo "L1AXI-GATE-FAIL"; exit 1; }
echo "== L1AXI gate PASS =="
