#!/usr/bin/env bash
# verif/l1/run-l1d-gate.sh — standalone unit gate for ven_l1d (P1-1 step 1, the L1
# data array + line-fill FSM). Builds the self-checking tb_l1d with Verilator
# --binary and asserts L1D-GATE-OK (cold miss→line-fill→hit, whole-line fill,
# write-through, 2-way LRU eviction). Run from the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

# REVIEW2 M-04: run the SAME checks at TWO geometries. ven_l1d advertised L1_SETS but
# hard-coded a 7-bit set index and a 20-bit tag, so an override indexed dc_tag/dc_val
# past their end AND split the address at the wrong bit -- silently wrong data, not a
# compile error. The 128 run is the regression; the 64 run is what actually proves the
# split now FOLLOWS the parameter. A 64-set build of the old body could not pass.
run_one() {  # <sets>
  local sets="$1"
  local dir="$OBJ/s$sets"
  mkdir -p "$dir"
  verilator --binary -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
      -Wno-INITIALDLY -Wno-IMPLICITSTATIC --top-module tb_l1d \
      -GTB_L1_SETS="$sets" -Mdir "$dir" -o tb_l1d \
      "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/tb_l1d.sv" > "$dir/build.log" 2>&1 \
      || { echo "L1D-GATE-FAIL (build, L1_SETS=$sets)"; tail -20 "$dir/build.log"; exit 1; }
  local out
  out="$("$dir/tb_l1d" 2>&1)"
  echo "$out"
  grep -q "L1D-GATE-OK" <<<"$out" || { echo "L1D-GATE-FAIL (L1_SETS=$sets)"; exit 1; }
  echo "-- L1D gate PASS at L1_SETS=$sets --"
}

run_one 128
run_one 64
echo "== L1D gate PASS (both geometries: the set/tag split follows L1_SETS) =="
