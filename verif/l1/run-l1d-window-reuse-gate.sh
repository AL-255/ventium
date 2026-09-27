#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ventium-l1d-window-reuse.XXXXXX")"
echo "Artifacts: $OUT"
for top in tb_l1d_window_reuse tb_l1d_coherence tb_l1d_hit_stream; do
    extra=()
    if [[ "$top" == tb_l1d_hit_stream ]]; then extra+=(+define+VEN_L1D_HIT_STREAM); fi
    "$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
        -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
        -Werror-LATCH -Werror-UNOPTFLAT +define+VEN_L1D_WINDOW_REUSE "${extra[@]}" \
        --top-module "$top" -Mdir "$OUT/$top" \
        "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/$top.sv" \
        > "$OUT/$top.build.log" 2>&1 || { tail -50 "$OUT/$top.build.log"; exit 1; }
    "$OUT/$top/V$top"
done
