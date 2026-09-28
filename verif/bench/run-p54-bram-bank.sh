#!/usr/bin/env bash
# Bounded cycle/byte-enable contract for the FPGA BRAM feasibility macro.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="$(mktemp -d /tmp/ventium-p54-bram-bank.XXXXXX)"
echo "Artifacts: $out"
timeout 90s "$root/tools/verilator_serial.sh" --binary --timing --assert -sv \
  -Wall -Wno-UNUSED -Wno-fatal -Werror-LATCH -Werror-UNOPTFLAT \
  --top-module tb_p54_bram_bank -Mdir "$out" \
  "$root/rtl/mem/ven_p54_bram_bank.sv" \
  "$root/verif/bench/tb_p54_bram_bank.sv" > "$out/build.log" 2>&1 || {
    tail -50 "$out/build.log"
    exit 1
  }
timeout 20s "$out/Vtb_p54_bram_bank"
