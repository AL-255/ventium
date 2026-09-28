#!/usr/bin/env bash
# Bounded full-seam two-bank resident-hit and cancellation microcheck.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$root/tools/build_scope.sh" --is-active; then
  exec "$root/tools/build_scope.sh" -- bash "$0" "$@"
fi
out="$(mktemp -d "${TMPDIR:-/tmp}/ventium-l1axi-pair-hit.XXXXXX")"
echo "Artifacts: $out"
timeout --signal=TERM --kill-after=10s 300s "$root/tools/verilator_serial.sh" \
  --binary --timing --assert -sv +define+AXI_BFM_MON \
  +define+VEN_P54_DUAL_HIT +define+VEN_L1D_BANKED_DATA \
  -Wall -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-fatal \
  -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
  -Werror-LATCH -Werror-UNOPTFLAT \
  --top-module tb_l1axi_pair_hit -Mdir "$out" \
  "$root/rtl/mem/ven_cdc_afifo.sv" \
  "$root/rtl/mem/ven_reset_sync.sv" \
  "$root/rtl/mem/ven_axi_cdc.sv" \
  "$root/rtl/mem/ven_p54_bank_arb.sv" \
  "$root/rtl/mem/ven_p54_hit_return.sv" \
  "$root/rtl/mem/ven_l1d.sv" \
  "$root/rtl/mem/ven_axi_master.sv" \
  "$root/rtl/northbridge/ven_cachemap.sv" \
  "$root/rtl/mem/ventium_l1_axi.sv" \
  "$root/verif/l1/axi_slave_bfm.sv" \
  "$root/verif/l1/tb_l1axi_pair_hit.sv" > "$out/build.log" 2>&1 || {
    tail -50 "$out/build.log"
    exit 1
  }
timeout --signal=TERM --kill-after=10s 20s "$out/Vtb_l1axi_pair_hit"
