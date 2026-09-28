#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/ventium-l1d-load64.XXXXXX")"
echo "Artifacts: $OUT"
extra_window=()
if [[ "${1:-}" == "--two-window" ]]; then
    extra_window+=(+define+VEN_L1D_TWO_WINDOW_REUSE)
elif [[ $# -ne 0 ]]; then
    echo "usage: $0 [--two-window]" >&2
    exit 2
fi
# Include fill-forward so the partial-window negative checks exercise the
# actual optimization used in the integration profile, not a dead path.
"$ROOT/tools/verilator_serial.sh" --binary --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
    -Werror-LATCH -Werror-UNOPTFLAT +define+VEN_FP_LOAD64 \
    +define+VEN_L1D_WINDOW_REUSE +define+VEN_L1D_FILL_FORWARD \
    "${extra_window[@]}" \
    --top-module tb_l1d_load64 -Mdir "$OUT/obj" \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/verif/l1/tb_l1d_load64.sv" \
    > "$OUT/build.log" 2>&1 || { tail -50 "$OUT/build.log"; exit 1; }
"$OUT/obj/Vtb_l1d_load64"
