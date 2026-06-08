#!/usr/bin/env bash
# verif/l1/run-l1d-gate.sh — standalone unit gate for ven_l1d (P1-1 step 1, the L1
# data array + line-fill FSM). Builds the self-checking tb_l1d with Verilator
# --binary and asserts L1D-GATE-OK (cold miss→line-fill→hit, whole-line fill,
# write-through, 2-way LRU eviction). Run from the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC --top-module tb_l1d -Mdir "$OBJ" -o tb_l1d \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/tb_l1d.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L1D-GATE-FAIL (build)"; tail -20 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1d" 2>&1)"
echo "$OUT"
grep -q "L1D-GATE-OK" <<<"$OUT" || { echo "L1D-GATE-FAIL"; exit 1; }
echo "== L1D gate PASS =="
