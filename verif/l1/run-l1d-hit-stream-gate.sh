#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ventium-l1d-hit-stream.XXXXXX")"
echo "Artifacts: $OUT"
"$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
    -Werror-LATCH -Werror-UNOPTFLAT +define+VEN_L1D_HIT_STREAM \
    --top-module tb_l1d_hit_stream -Mdir "$OUT" \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/tb_l1d_hit_stream.sv" \
    > "$OUT/build.log" 2>&1 || { tail -50 "$OUT/build.log"; exit 1; }
"$OUT/Vtb_l1d_hit_stream"
