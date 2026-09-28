#!/usr/bin/env bash
# verif/l1/run-l1d-gate.sh — standalone unit gate for ven_l1d (P1-1 step 1, the L1
# data array + line-fill FSM). Builds the self-checking tb_l1d with Verilator
# --binary and asserts L1D-GATE-OK (cold miss→line-fill→hit, whole-line fill,
# write-through, 2-way LRU eviction). Run from the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
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
# The default policy keeps fills fully serialized.  The opt-in candidate must
# prove that a resident, different-set hit uses the existing registered read
# path while the active fill continues to own every backing beat.
run_one 128 "-DVEN_L1D_HIT_UNDER_FILL" "HIT_UNDER_FILL"
run_one 64  "-DVEN_L1D_HIT_UNDER_FILL" "HIT_UNDER_FILL"
# Same-line fill-forward is deliberately a separate opt-in from the resident
# different-set HUF path.  It may use only physical words already returned by
# the active WRAP fill, must retain the registered response timing, and must
# suppress that response when a snoop poisons the transaction.
run_one 128 "-DVEN_L1D_FILL_FORWARD" "FILL_FORWARD"
run_one 64  "-DVEN_L1D_FILL_FORWARD" "FILL_FORWARD"
# The two opt-ins use the same registered capture window but distinct access
# domains (other resident set vs. already-arrived word of the filling line).
# Exercise their conjunction explicitly so a future predicate refactor cannot
# accidentally make one path steal or duplicate the other's response.
run_one 128 "-DVEN_L1D_HIT_UNDER_FILL -DVEN_L1D_FILL_FORWARD" "HUF_PLUS_FILL_FORWARD"
run_one 64  "-DVEN_L1D_HIT_UNDER_FILL -DVEN_L1D_FILL_FORWARD" "HUF_PLUS_FILL_FORWARD"
# The full-PC candidate also preserves complete resident windows across
# unrelated stores. Exercise all three policies together at both geometries;
# the standalone window-keep suite covers its more targeted store races.
run_one 128 "-DVEN_L1D_HIT_UNDER_FILL -DVEN_L1D_FILL_FORWARD -DVEN_L1D_WINDOW_REUSE -DVEN_L1D_WINDOW_KEEP_STORE" "HUF_FF_KEEP_STORE"
run_one 64  "-DVEN_L1D_HIT_UNDER_FILL -DVEN_L1D_FILL_FORWARD -DVEN_L1D_WINDOW_REUSE -DVEN_L1D_WINDOW_KEEP_STORE" "HUF_FF_KEEP_STORE"
# Full-PC gameplay also enables tag-selective store invalidation.  Verify that
# exact policy conjunction separately; the non-tagged configuration is retained
# because it has materially different replacement/invalidation behavior.
run_one 128 "-DVEN_L1D_HIT_UNDER_FILL -DVEN_L1D_FILL_FORWARD -DVEN_L1D_WINDOW_REUSE -DVEN_L1D_WINDOW_KEEP_STORE -DVEN_L1D_TAG_INVALIDATE" "HUF_FF_KEEP_STORE_TAG"
run_one 64  "-DVEN_L1D_HIT_UNDER_FILL -DVEN_L1D_FILL_FORWARD -DVEN_L1D_WINDOW_REUSE -DVEN_L1D_WINDOW_KEEP_STORE -DVEN_L1D_TAG_INVALIDATE" "HUF_FF_KEEP_STORE_TAG"
# Sharing bank zero's ordinary read port with a crossing dword changes the
# captured first-line image. Run the same crossing/return tests with window
# reuse enabled, at both supported set counts.
run_one 128 "-DVEN_L1D_BANKED_DATA -DVEN_L1D_BANK0_SHARED_XLINE -DVEN_L1D_WINDOW_REUSE" "BANK0_SHARED_XLINE"
run_one 64  "-DVEN_L1D_BANKED_DATA -DVEN_L1D_BANK0_SHARED_XLINE -DVEN_L1D_WINDOW_REUSE" "BANK0_SHARED_XLINE"
# Qualify landed-word forwarding against the complete resident-window and
# code-buffer datapaths, in both the packed release storage and banked FPGA
# candidate. This TB keeps c_code low; code-fill stream behavior has its own
# gate, while these runs stress data fill/snoop/response ownership.
run_one 128 "-DVEN_L1D_FILL_FORWARD -DVEN_L1D_WINDOW_REUSE -DVEN_L1D_CODE_BUFFER -DVEN_L1D_CODE_STREAM" "PACKED_FF_WINDOW_CODE"
run_one 128 "-DVEN_L1D_BANKED_DATA -DVEN_L1D_BANK0_SHARED_XLINE -DVEN_L1D_FILL_FORWARD -DVEN_L1D_WINDOW_REUSE -DVEN_L1D_CODE_BUFFER -DVEN_L1D_CODE_STREAM" "BANKED_FF_WINDOW_CODE"
# REVIEW1_Aug2 H-07: the finding lives in the VEN_L1_HONOR_CD build -- that is the
# configuration where BYPASS_RD_EN was 0 and a non-cacheable read of a resident line
# was served from the ARRAY (stale post-CD data; for MMIO, duplicated or suppressed
# read side effects). The gate ran only the default build, so [9c] never exercised it
# and the fix would have been untested in CI. Measured on the pre-fix tree this run
# reports: FAIL nc read of resident line is FRESH: got a5a54200 exp deadbeef.
run_one 128 "-DVEN_L1_HONOR_CD" "HONOR_CD"
echo "== L1D gate PASS (both geometries + the VEN_L1_HONOR_CD read-bypass path) =="
