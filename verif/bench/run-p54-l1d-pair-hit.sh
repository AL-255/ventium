#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(mktemp -d /tmp/ventium-p54-l1d-pair-hit.XXXXXX)"
echo "Artifacts: $out"
timeout 420s "$root/tools/verilator_serial.sh" --binary --assert -sv \
    -Wall -Wno-UNUSED -Wno-fatal \
    -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN \
    -Werror-MULTIDRIVEN -Werror-LATCH -Werror-UNOPTFLAT \
    +define+VEN_L1D_BANKED_DATA +define+VEN_P54_DUAL_HIT \
    --top-module tb_l1d_pair_hit -Mdir "$out" \
    "$root/rtl/mem/ven_p54_bank_arb.sv" \
    "$root/rtl/mem/ven_p54_hit_return.sv" \
    "$root/rtl/mem/ven_l1d.sv" \
    "$root/verif/bench/tb_l1d_pair_hit.sv" > "$out/build.log" 2>&1 || {
        tail -60 "$out/build.log"
        exit 1
    }
timeout 30s "$out/Vtb_l1d_pair_hit"
