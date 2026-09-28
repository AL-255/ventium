#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(mktemp -d "${P54_CODE_BUFFER_OUTBASE:-/tmp}/ventium-p54-l1d-code-buffer.XXXXXX")"
echo "Artifacts: $out"
SECONDS=0
run() {
    local remaining=$((540 - SECONDS))
    (( remaining > 0 )) || { echo "nine-minute code-buffer gate budget expired" >&2; exit 1; }
    timeout --signal=TERM --kill-after=10s "$remaining" "$@"
}
for variant in packed banked banked_window banked_forward banked_code_stream banked_both_forward banked_hit_under_fill banked_hit_under_fill_tag banked_tag banked_tag_pair; do
    defines=(+define+VEN_L1D_CODE_BUFFER)
    if [[ "$variant" == banked* ]]; then
        defines+=(+define+VEN_L1D_BANKED_DATA)
    fi
    if [[ "$variant" == banked_window ]]; then
        defines+=(+define+VEN_L1D_WINDOW_REUSE)
    fi
    if [[ "$variant" == banked_forward ]]; then
        defines+=(+define+VEN_L1D_FILL_FORWARD)
    fi
    if [[ "$variant" == banked_code_stream || "$variant" == banked_both_forward ]]; then
        defines+=(+define+VEN_L1D_CODE_STREAM)
    fi
    if [[ "$variant" == banked_both_forward ]]; then
        defines+=(+define+VEN_L1D_FILL_FORWARD)
    fi
    if [[ "$variant" == banked_tag || "$variant" == banked_tag_pair ]]; then
        defines+=(+define+VEN_L1D_CODE_TAG_INVALIDATE +define+VEN_L1D_CODE_STREAM)
    fi
    if [[ "$variant" == banked_hit_under_fill || "$variant" == banked_hit_under_fill_tag ]]; then
        defines+=(+define+VEN_L1D_HIT_UNDER_FILL)
    fi
    if [[ "$variant" == banked_hit_under_fill_tag ]]; then
        defines+=(+define+VEN_L1D_CODE_TAG_INVALIDATE +define+VEN_L1D_CODE_STREAM)
    fi
    if [[ "$variant" == banked_tag_pair ]]; then
        defines+=(+define+VEN_P54_DUAL_STORE_PAIR)
    fi
    run "$root/tools/verilator_serial.sh" --binary --assert -sv \
        -Wall -Wno-UNUSED -Wno-fatal \
        -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
        -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
        "${defines[@]}" \
        --top-module tb_l1d_code_buffer -Mdir "$out/$variant" \
        "$root/rtl/mem/ven_l1d.sv" \
        "$root/verif/bench/tb_l1d_code_buffer.sv" > "$out/$variant.build.log" 2>&1 || {
            tail -60 "$out/$variant.build.log"
            exit 1
        }
    run "$out/$variant/Vtb_l1d_code_buffer"
done
