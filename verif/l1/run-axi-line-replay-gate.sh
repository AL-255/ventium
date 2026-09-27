#!/usr/bin/env bash
# Cache-line replay regression: prove the shipping double-fill discards one
# stale INCR8 response, and prove the VEN_SINGLE_FILL mutation leaks it.  The
# test is deliberately direct to ven_axi_master; no shared BFM/RTL is changed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

build_and_run() {
    local tag="$1"
    local define="$2"
    local build="$OBJ/$tag"
    CCACHE_DISABLE=1 "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" \
        --binary -sv --assert -Wno-UNUSED -Wno-DECLFILENAME \
        --top-module tb_axi_line_replay -Mdir "$build" -o tb_axi_line_replay \
        $define \
        "$ROOT/rtl/mem/ven_axi_master.sv" \
        "$ROOT/verif/l1/tb_axi_line_replay.sv" \
        > "$OBJ/$tag.build.log" 2>&1 \
        || { echo "AXI-LINE-REPLAY-GATE-FAIL ($tag build)"; tail -60 "$OBJ/$tag.build.log"; exit 1; }
    "$build/tb_axi_line_replay" 2>&1
}

DEFAULT_OUT="$(build_and_run default '')"
echo "$DEFAULT_OUT"
grep -q 'AXI-LINE-REPLAY-GATE-OK' <<<"$DEFAULT_OUT" \
    || { echo "AXI-LINE-REPLAY-GATE-FAIL (default)"; exit 1; }

MUTANT_OUT="$(build_and_run single-fill '+define+VEN_SINGLE_FILL')"
echo "$MUTANT_OUT"
grep -q 'AXI-LINE-REPLAY-GATE-FAIL' <<<"$MUTANT_OUT" \
    || { echo "AXI-LINE-REPLAY-GATE-FAIL (mutation unexpectedly passed)"; exit 1; }
grep -q 'stale_acks=8' <<<"$MUTANT_OUT" \
    || { echo "AXI-LINE-REPLAY-GATE-FAIL (mutation did not expose stale line)"; exit 1; }
if grep -q 'AXI-LINE-REPLAY-GATE-OK' <<<"$MUTANT_OUT"; then
    echo "AXI-LINE-REPLAY-GATE-FAIL (mutation emitted OK marker)"
    exit 1
fi
echo "AXI-LINE-REPLAY-MUTATION-CONTROL-OK"

for policy in 0 1; do
    HEALTHY_OUT="$(build_and_run "healthy-$policy" "-GREPLAY=$policy -GSTALE_FIRST=0")"
    echo "$HEALTHY_OUT"
    grep -q 'AXI-LINE-REPLAY-GATE-OK' <<<"$HEALTHY_OUT" \
        || { echo "AXI-LINE-REPLAY-GATE-FAIL (healthy policy=$policy)"; exit 1; }
done
UNQUALIFIED_OUT="$(build_and_run unqualified '-GREPLAY=0')"
echo "$UNQUALIFIED_OUT"
grep -q 'stale_acks=8' <<<"$UNQUALIFIED_OUT" \
    || { echo "AXI-LINE-REPLAY-GATE-FAIL (unqualified backend not detected)"; exit 1; }
if grep -q 'AXI-LINE-REPLAY-GATE-OK' <<<"$UNQUALIFIED_OUT"; then
    echo "AXI-LINE-REPLAY-GATE-FAIL (unqualified backend passed)"
    exit 1
fi
echo "AXI-LINE-REPLAY-POLICY-GATE-OK"
