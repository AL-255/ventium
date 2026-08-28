#!/usr/bin/env bash
# verif/l1/run-l1axi-lock-gate.sh
# REVIEW1_Aug3 R2-H08: locked-RMW ownership of the local DMA requester.
#
# The pin-level biu_p5 path holds LOCK# across a locked RMW; the L1/AXI path
# now holds the local DMA requester off for the same window (lock_owned in
# ventium_l1_axi gates nb_dma_req). This gate builds with VEN_NB_DMA (the DMA
# port live) and checks the FSM-level contract -- the only honest level in this
# checkout, where the no-L2 generate ties the DMA response path off:
#   A  control: an unheld DMA request forwards immediately
#   B  a locked read takes ownership; an adversarial DMA write requested on
#      EVERY cycle of the window never forwards
#   C  the completing locked write releases ownership; the pending DMA forwards
#   D  an unlocked core request (the fault-abort shape) releases ownership
#   E  reset releases ownership
# The end-to-end "second master completes a write and the RMW retries/loses
# nothing" case needs the northbridge's live DMA path (L2 restoration, R2-H10).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT

verilator --binary -sv --assert -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC +define+VEN_NB_DMA --top-module tb_l1axi_lock -Mdir "$OBJ" -o tb \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" "$ROOT/verif/l1/axi_slave_bfm.sv" \
    "$ROOT/verif/l1/tb_l1axi_lock.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L1AXILOCK-GATE-FAIL (build)"; tail -25 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb" 2>&1)"
echo "$OUT" | grep -vE "^- |Verilator:"

if ! grep -q "L1AXILOCK-GATE-OK" <<<"$OUT"; then
  echo "FATAL: the locked-RMW window does not hold the local DMA requester."
  exit 1
fi
