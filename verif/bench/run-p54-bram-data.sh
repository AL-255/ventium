#!/usr/bin/env bash
# Bounded two-lane/collision/held-response contract for FPGA BRAM data banks.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$root/tools/build_scope.sh" --is-active; then
  exec "$root/tools/build_scope.sh" -- bash "$0" "$@"
fi
out="$(mktemp -d "${TMPDIR:-/tmp}/ventium-p54-bram-data.XXXXXX")"
echo "Artifacts: $out"
timeout --signal=TERM --kill-after=10s 300s "$root/tools/verilator_serial.sh" \
  --binary --timing --assert -sv -Wall -Wno-UNUSED -Wno-fatal \
  -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
  -Werror-LATCH -Werror-UNOPTFLAT \
  --top-module tb_p54_bram_data -Mdir "$out" \
  "$root/rtl/mem/ven_p54_bram_bank.sv" \
  "$root/rtl/mem/ven_p54_bram_data.sv" \
  "$root/verif/bench/tb_p54_bram_data.sv" > "$out/build.log" 2>&1 || {
    tail -50 "$out/build.log"
    exit 1
  }
timeout --signal=TERM --kill-after=10s 20s "$out/Vtb_p54_bram_data"
