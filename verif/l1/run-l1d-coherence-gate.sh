#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Directed transactional-invalidation regression for ven_l1d.  It covers the
# registered-hit window plus flush/snoop races during a line fill and on the
# response edge.  Keep it separate from run-l1d-gate.sh: the latter is the
# broad data/LRU sweep, while this one is deliberately timing-sensitive.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- "$0" "$@"
fi

OBJ="$(mktemp -d "${TMPDIR:-/tmp}/ventium-l1d-coherence.XXXXXX")"
trap 'rm -rf -- "$OBJ"' EXIT

run_one() {
  local label="$1"; shift
  local dir="$OBJ/$label" out
  mkdir "$dir"
  "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary --assert -sv \
    -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE \
    "$@" --top-module tb_l1d_coherence -Mdir "$dir" -o tb_l1d_coherence \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/tb_l1d_coherence.sv" \
    >"$dir/build.log" 2>&1 \
    || { echo "L1D-COHERENCE-GATE-FAIL (build $label)"; tail -40 "$dir/build.log"; exit 1; }
  out="$("$dir/tb_l1d_coherence" 2>&1)"
  echo "$out"
  grep -q "L1D_COHERENCE: PASS" <<<"$out" || {
    echo "L1D-COHERENCE-GATE-FAIL (run $label)"
    exit 1
  }
}
run_one baseline
run_one huf_ff_keep_store -DVEN_L1D_HIT_UNDER_FILL -DVEN_L1D_FILL_FORWARD \
  -DVEN_L1D_WINDOW_REUSE -DVEN_L1D_WINDOW_KEEP_STORE
run_one huf_ff_keep_store_tag -DVEN_L1D_HIT_UNDER_FILL -DVEN_L1D_FILL_FORWARD \
  -DVEN_L1D_WINDOW_REUSE -DVEN_L1D_WINDOW_KEEP_STORE -DVEN_L1D_TAG_INVALIDATE
echo "== L1D coherence race gate PASS =="
