#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="${TMPDIR:-$root/tmp/build-tmp}"
mkdir -p "$scratch"
out="$(mktemp -d "$scratch/ventium-p54-l1d-pair-hit.XXXXXX")"
echo "Artifacts: $out"
extra_defines=()
if [[ "${1:-}" == "--comb-ack" ]]; then
    extra_defines=(+define+VEN_L1D_COMB_ACK)
elif [[ "${1:-}" == "--legacy-capture-pair" ]]; then
    extra_defines=(+define+VEN_P54_DUAL_HIT_LEGACY_CAPTURE +define+VEN_L1D_WINDOW_REUSE)
elif [[ "${1:-}" == "--byte-pair" ]]; then
    extra_defines=(+define+VEN_P54_DUAL_HIT_LEGACY_CAPTURE +define+VEN_L1D_WINDOW_REUSE
                   +define+VEN_P54_DUAL_BYTE_LOAD_PAIR)
elif [[ "${1:-}" == "--prime-pair" ]]; then
    extra_defines=(+define+VEN_P54_DUAL_HIT_LEGACY_CAPTURE +define+VEN_L1D_WINDOW_REUSE
                   +define+VEN_PIPE_MEM_CHAIN +define+VEN_PIPE_REG_LOAD_PRIME
                   +define+VEN_P54_DUAL_LOAD_PRIME)
elif [[ "${1:-}" == "--byte-prime-pair" ]]; then
    extra_defines=(+define+VEN_P54_DUAL_HIT_LEGACY_CAPTURE +define+VEN_L1D_WINDOW_REUSE
                   +define+VEN_PIPE_MEM_CHAIN +define+VEN_PIPE_REG_LOAD_PRIME
                   +define+VEN_P54_DUAL_LOAD_PRIME +define+VEN_P54_DUAL_BYTE_LOAD_PAIR)
elif [[ "${1:-}" == "--two-window" ]]; then
    extra_defines=(+define+VEN_P54_DUAL_HIT_LEGACY_CAPTURE +define+VEN_L1D_WINDOW_REUSE
                   +define+VEN_L1D_TWO_WINDOW_REUSE +define+VEN_PIPE_MEM_CHAIN
                   +define+VEN_PIPE_REG_LOAD_PRIME +define+VEN_P54_DUAL_LOAD_PRIME)
elif [[ "${1:-}" == "--byte-two-window" ]]; then
    extra_defines=(+define+VEN_P54_DUAL_HIT_LEGACY_CAPTURE +define+VEN_L1D_WINDOW_REUSE
                   +define+VEN_L1D_TWO_WINDOW_REUSE +define+VEN_PIPE_MEM_CHAIN
                   +define+VEN_PIPE_REG_LOAD_PRIME +define+VEN_P54_DUAL_LOAD_PRIME
                   +define+VEN_P54_DUAL_BYTE_LOAD_PAIR)
elif [[ "${1:-}" == "--byte-two-window-store" ]]; then
    extra_defines=(+define+VEN_P54_DUAL_HIT_LEGACY_CAPTURE +define+VEN_L1D_WINDOW_REUSE
                   +define+VEN_L1D_TWO_WINDOW_REUSE +define+VEN_L1D_WINDOW_KEEP_STORE
                   +define+VEN_L1D_TWO_WINDOW_KEEP_STORE +define+VEN_PIPE_MEM_CHAIN
                   +define+VEN_PIPE_REG_LOAD_PRIME +define+VEN_P54_DUAL_LOAD_PRIME
                   +define+VEN_P54_DUAL_BYTE_LOAD_PAIR)
elif [[ $# -ne 0 ]]; then
    echo "usage: $0 [--comb-ack|--legacy-capture-pair|--byte-pair|--prime-pair|--byte-prime-pair|--two-window|--byte-two-window|--byte-two-window-store]" >&2
    exit 2
fi
if [[ "${VEN_L1D_SHARED_BANK0:-0}" == "1" ]]; then
    extra_defines+=(+define+VEN_L1D_BANK0_SHARED_XLINE)
fi
timeout 420s "$root/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary --assert -sv \
    -Wall -Wno-UNUSED -Wno-fatal \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
    -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
    +define+VEN_L1D_BANKED_DATA +define+VEN_P54_DUAL_HIT \
    "${extra_defines[@]}" \
    --top-module tb_l1d_pair_hit -Mdir "$out" \
    "$root/rtl/mem/ven_p54_bank_arb.sv" \
    "$root/rtl/mem/ven_p54_hit_return.sv" \
    "$root/rtl/mem/ven_l1d.sv" \
    "$root/verif/bench/tb_l1d_pair_hit.sv" > "$out/build.log" 2>&1 || {
        tail -60 "$out/build.log"
        exit 1
    }
timeout 30s "$out/Vtb_l1d_pair_hit"
