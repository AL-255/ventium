#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# l2 lower-half streaming critical-word-first regression.  The optimization is
# deliberately opt-in: it must preserve one contiguous eight-beat DDR fill,
# return the lower-half request before the delayed tail, retain a normal hit
# after tag publication, and poison a fill hit by an overlapping invalidation.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

"$ROOT/tools/verilator_serial.sh" --binary --timing --assert -sv \
    -DVEN_L2_STREAM_CWF -DVEN_L2_PERF -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
    -Wno-DECLFILENAME -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    --top-module tb_l2_stream_cwf -Mdir "$OBJ" -o tb_l2_stream_cwf \
    "$ROOT/verif/l1/tb_l2_stream_cwf.sv" \
    "$ROOT/3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v" \
    "$ROOT/ao486-sim/stubs/sim_prims.sv" >"$OBJ/build.log" 2>&1 \
    || { echo "L2-STREAM-CWF-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$(stdbuf -o0 "$OBJ/tb_l2_stream_cwf" 2>&1)"
echo "$OUT" | grep -vE '^- |Verilator:'
grep -q "L2-STREAM-CWF-GATE-OK" <<<"$OUT" \
    || { echo "L2-STREAM-CWF-GATE-FAIL"; exit 1; }
echo "== L2 stream-CWF gate PASS =="
