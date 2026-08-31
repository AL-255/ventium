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
run_one() {  # <sets> [extra-defines] [label]
  local sets="$1"; local defs="${2:-}"; local label="${3:-}"
  local dir="$OBJ/s${sets}${label// /_}"
  mkdir -p "$dir"
  "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
      -Wno-INITIALDLY -Wno-IMPLICITSTATIC $defs --top-module tb_l1d \
      -GTB_L1_SETS="$sets" -Mdir "$dir" -o tb_l1d \
      "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/tb_l1d.sv" > "$dir/build.log" 2>&1 \
      || { echo "L1D-GATE-FAIL (build, L1_SETS=$sets $label)"; tail -20 "$dir/build.log"; exit 1; }
  local out
  out="$("$dir/tb_l1d" 2>&1)"
  echo "$out"
  grep -q "L1D-GATE-OK" <<<"$out" || { echo "L1D-GATE-FAIL (L1_SETS=$sets $label)"; exit 1; }
  echo "-- L1D gate PASS at L1_SETS=$sets $label --"
}

run_one 128
run_one 64
# REVIEW1_Aug2 H-07: the finding lives in the VEN_L1_HONOR_CD build -- that is the
# configuration where BYPASS_RD_EN was 0 and a non-cacheable read of a resident line
# was served from the ARRAY (stale post-CD data; for MMIO, duplicated or suppressed
# read side effects). The gate ran only the default build, so [9c] never exercised it
# and the fix would have been untested in CI. Measured on the pre-fix tree this run
# reports: FAIL nc read of resident line is FRESH: got a5a54200 exp deadbeef.
run_one 128 "-DVEN_L1_HONOR_CD" "HONOR_CD"
echo "== L1D gate PASS (both geometries + the VEN_L1_HONOR_CD read-bypass path) =="
