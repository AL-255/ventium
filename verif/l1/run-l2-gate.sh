#!/usr/bin/env bash
# verif/l1/run-l2-gate.sh — standalone unit gate for ven_l2 (the UltraRAM L2 cache
# controller). Builds the self-checking tb_l2 with Verilator --binary and asserts
# L2-GATE-OK: cold miss→fill (forward-during-fill), L2 hit (0 DDR reads), write-back
# (0 DDR writes on a store hit / write-allocate), clean vs dirty eviction (byte-correct
# writeback), sub-word + cross-line straddle stores, and downstream-latency tolerance.
# Run from the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC --top-module tb_l2 -Mdir "$OBJ" -o tb_l2 \
    "$ROOT/rtl/mem/ven_l2.sv" "$ROOT/verif/l1/tb_l2.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L2-GATE-FAIL (build)"; tail -30 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l2" 2>&1)"
echo "$OUT"
grep -q "L2-GATE-OK" <<<"$OUT" || { echo "L2-GATE-FAIL"; exit 1; }
echo "== L2 gate PASS =="
