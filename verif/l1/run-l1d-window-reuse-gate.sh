#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ventium-l1d-window-reuse.XXXXXX")"
echo "Artifacts: $OUT"
extra_window=()
if [[ "${1:-}" == "--two-window" ]]; then
    extra_window+=(+define+VEN_L1D_TWO_WINDOW_REUSE)
elif [[ "${1:-}" == "--two-window-keep-store" ]]; then
    extra_window+=(+define+VEN_L1D_TWO_WINDOW_REUSE +define+VEN_L1D_WINDOW_KEEP_STORE)
elif [[ "${1:-}" == "--two-window-preserve-store" ]]; then
    extra_window+=(+define+VEN_L1D_TWO_WINDOW_REUSE +define+VEN_L1D_WINDOW_KEEP_STORE
                   +define+VEN_L1D_TWO_WINDOW_KEEP_STORE)
elif [[ $# -ne 0 ]]; then
    echo "usage: $0 [--two-window|--two-window-keep-store|--two-window-preserve-store]" >&2
    exit 2
fi
for top in tb_l1d_window_reuse tb_l1d_coherence tb_l1d_hit_stream; do
    extra=()
    if [[ "$top" == tb_l1d_hit_stream ]]; then extra+=(+define+VEN_L1D_HIT_STREAM); fi
    "$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
        -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
        -Werror-LATCH -Werror-UNOPTFLAT +define+VEN_L1D_WINDOW_REUSE \
        "${extra_window[@]}" "${extra[@]}" \
        --top-module "$top" -Mdir "$OUT/$top" \
        "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/$top.sv" \
        > "$OUT/$top.build.log" 2>&1 || { tail -50 "$OUT/$top.build.log"; exit 1; }
    "$OUT/$top/V$top"
done
