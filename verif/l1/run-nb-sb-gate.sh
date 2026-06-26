#!/usr/bin/env bash
# verif/l1/run-nb-sb-gate.sh — Phase E.system gate: the northbridge ↔ southbridge link as
# a unit. Builds tb_nb_sb (ventium_l1_axi EN_L2=1 + ven_southbridge + DDR slave + synthetic
# CPU) and asserts NBSB-GATE-OK: CPU device-aperture access routes NB.mmio_* → the SB
# framebuffer; the SB's 8237 bus-masters memory through NB.dma_* → L2 coherently (a DMA
# write to a CPU-cached line snoop-invalidates the L1 so the CPU re-read sees it).
# Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    +define+VEN_NB_DMA +define+VEN_NB_MMIO +define+VEN_DBG_CORE +define+VEN_DBG_L2 \
    --top-module tb_nb_sb -Mdir "$OBJ" -o tb_nb_sb \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/rtl/northbridge/ven_l2.sv" \
    "$ROOT/rtl/northbridge/ven_northbridge.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/rtl/northbridge/ven_hostbridge_cfg.sv" "$ROOT/rtl/soc/ven_i8237.sv" \
    "$ROOT/rtl/soc/ven_i8237_dma.sv" "$ROOT/rtl/northbridge/ven_southbridge.sv" \
    "$ROOT/verif/l1/axi_slave_bfm.sv" "$ROOT/verif/l1/tb_nb_sb.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "NBSB-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_nb_sb" 2>&1)"
echo "$OUT"
grep -q "NBSB-GATE-OK" <<<"$OUT" || { echo "NBSB-GATE-FAIL"; exit 1; }
echo "== northbridge ↔ southbridge integration gate PASS =="
