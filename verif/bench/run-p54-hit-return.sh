#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(mktemp -d /tmp/ventium-p54-hit-return.XXXXXX)"
echo "Artifacts: $out"
timeout 420s "$root/tools/verilator_serial.sh" --binary --assert -sv \
    -Wall -Wno-UNUSED -Wno-fatal -Werror-LATCH -Werror-UNOPTFLAT \
    --top-module tb_p54_hit_return -Mdir "$out" \
    "$root/rtl/mem/ven_p54_bank_arb.sv" \
    "$root/rtl/mem/ven_p54_hit_return.sv" \
    "$root/verif/bench/tb_p54_hit_return.sv" > "$out/build.log" 2>&1 || {
        tail -60 "$out/build.log"
        exit 1
    }
timeout 30s "$out/Vtb_p54_hit_return"
