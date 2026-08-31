#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-l1axi-rlast-gate.sh — REVIEW2 M-08: RLAST/beat-count mismatch RECOVERY.
#
# ven_axi_master exits a read burst on its own beat count, not on RLAST. Reporting a
# mismatch (rlast_err -> bus_err) was already in place; the review ALSO requires
# draining/recovering DETERMINISTICALLY. No existing test could reach that path,
# because a compliant slave never produces a mismatch -- so axi_slave_bfm gained
# RLAST_EXTRA / RLAST_EARLY fault injection and this gate drives both.
#
#   mode 0  LATE RLAST : the slave sends one beat MORE than arlen and withholds RLAST.
#                        Without the drain the master returns to idle with a beat still
#                        in flight, which the NEXT burst consumes as its own data.
#   mode 1  EARLY RLAST: the slave ends the burst a beat early. Without the early exit
#                        the master waits for a beat that never arrives and only the
#                        #34 watchdog rescues it -- a timeout, not a defined recovery.
#
# Each mode must (a) raise bus_err and (b) NOT deadlock: a SUBSEQUENT read must still
# complete, which is what actually demonstrates the channel was resynchronised.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

run_mode() {  # <mode> <label>
  local mode="$1"
  local label="$2"
  local dir="$OBJ/m$mode"
  mkdir -p "$dir"
  # NOTE: built with --no-assert on purpose. ven_axi_master carries an rlast_align SVA
  # that polices exactly the property this gate DELIBERATELY violates, so with
  # assertions enabled the simulation aborts on the injected fault before the
  # testbench's own recovery checks can run. The SVA remains live in every other
  # build (and in the bus-sva gate); here the injected mismatch is the stimulus, not a
  # bug, and what is being graded is the RECOVERY.
  verilator -j "${VL_J:-1}" --binary -sv --no-assert -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
      -Wno-WIDTH -Wno-IMPLICITSTATIC --top-module tb_l1axi_rlast \
      -GTB_MODE="$mode" -Mdir "$dir" -o tb_l1axi_rlast \
      "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
      "$ROOT/rtl/mem/ven_cdc_afifo.sv" "$ROOT/rtl/mem/ven_axi_cdc.sv" \
      "$ROOT/rtl/mem/ven_reset_sync.sv" \
      "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" "$ROOT/verif/l1/axi_slave_bfm.sv" \
      "$ROOT/verif/l1/tb_l1axi_rlast.sv" > "$dir/build.log" 2>&1 \
      || { echo "L1AXIRLAST-GATE-FAIL (build, mode $mode)"; tail -25 "$dir/build.log"; exit 1; }
  echo "---- $label ----"
  # The binary may exit nonzero on an injected fault; the OK marker decides, not $?.
  local out rc
  set +e
  out="$("$dir/tb_l1axi_rlast" 2>&1)"
  rc=$?
  set -e
  echo "$out"
  [ "$rc" != 124 ] || { echo "L1AXIRLAST-GATE-FAIL (timeout, mode $mode)"; exit 1; }
  grep -q "L1AXIRLAST-GATE-OK" <<<"$out" || { echo "L1AXIRLAST-GATE-FAIL (mode $mode)"; exit 1; }
}

run_mode 0 "LATE RLAST (extra beat, RLAST withheld)"
run_mode 1 "EARLY RLAST (burst ends a beat early)"
echo "== L1AXI RLAST-recovery gate PASS (both mismatch directions reported AND recovered) =="
