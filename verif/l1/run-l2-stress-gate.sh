#!/usr/bin/env bash
# verif/l1/run-l2-stress-gate.sh — capacity-OVERRUN stress + DDR-interaction capture for
# ven_l2. Drives an 8x-capacity working set so the cache thrashes (conflict + capacity
# misses, dirty evictions, writeback churn), golden-checks every read, captures the
# cache↔DDR transaction trace + per-phase stats, and proves no dirty data is lost across
# the overrun (final cold-sweep flush → DDR must equal the golden model). Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC --top-module tb_l2_stress -Mdir "$OBJ" -o tb_l2_stress \
    "$ROOT/rtl/northbridge/ven_l2.sv" "$ROOT/verif/l1/tb_l2_stress.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L2STRESS-GATE-FAIL (build)"; tail -30 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l2_stress" 2>&1)"
echo "$OUT"
grep -q "L2STRESS-GATE-OK" <<<"$OUT" || { echo "L2STRESS-GATE-FAIL"; exit 1; }
echo "== L2 stress gate PASS =="
