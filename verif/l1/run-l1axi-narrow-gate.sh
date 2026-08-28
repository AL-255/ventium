#!/usr/bin/env bash
# verif/l1/run-l1axi-narrow-gate.sh — REVIEW_Aug3 C-01 gate for H-11 narrow reads.
#
# Runs tb_l1axi_narrow in the two configurations the finding names:
#   (a) the DEPLOYED direct single-clock build (no defines — the D-side ven_cachemap
#       added for C-01 makes the VGA aperture non-cacheable in the DEFAULT build, so
#       the narrow path needs no VEN_L1_HONOR_CD);
#   (b) +VEN_AXI_CDC, across the four core:axi clock ratios of the CDC gate — the
#       narrow bits must cross inside the command FIFO, and both CDC FSMs must count
#       the 1-2 beat response, not the constant LINE_BEATS.
# The TB asserts exact ARADDR/ARSIZE/ARLEN, RLAST acceptance, response counts, ONE
# AR per architectural device read (against a read-to-clear slave), and bus_err==0.
# `make l1` globs verif/l1/run-*.sh, so this gate is picked up automatically.
# Run from the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

# NO blanket -Wno-WIDTH (keep the remap-truncation class visible) — same discipline
# as run-l1axi-cdc-gate.sh. UNOPTFLAT stays ON to catch a CDC comb loop at build.
# +define+AXI_BFM_MON exposes the BFM's AR-count/burst-beat monitor ports (this TB
# is the only consumer; the other seven BFM users build without them).
COMMON_WNO="-Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-IMPLICITSTATIC"

# ---- (a) direct single-clock (the deployed define set: none) -------------------
verilator --binary -sv --assert +define+AXI_BFM_MON $COMMON_WNO \
    --top-module tb_l1axi_narrow -Mdir "$OBJ/direct" -o tb_l1axi_narrow \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/verif/l1/axi_slave_bfm.sv" "$ROOT/verif/l1/tb_l1axi_narrow.sv" \
    > "$OBJ/build-direct.log" 2>&1 \
    || { echo "L1AXINARROW-GATE-FAIL (direct build)"; tail -40 "$OBJ/build-direct.log"; exit 1; }

OUT="$("$OBJ/direct/tb_l1axi_narrow" 2>&1)"
echo "$OUT"
grep -q "L1AXINARROW-GATE-OK" <<<"$OUT" || { echo "L1AXINARROW-GATE-FAIL (direct)"; exit 1; }

# ---- (b) dual-clock CDC, four core:axi ratios ----------------------------------
verilator --binary -sv --assert +define+VEN_AXI_CDC +define+AXI_BFM_MON $COMMON_WNO \
    --top-module tb_l1axi_narrow -Mdir "$OBJ/cdc" -o tb_l1axi_narrow \
    "$ROOT/rtl/mem/ven_cdc_afifo.sv" "$ROOT/rtl/mem/ven_reset_sync.sv" \
    "$ROOT/rtl/mem/ven_axi_cdc.sv" "$ROOT/rtl/mem/ven_l1d.sv" \
    "$ROOT/rtl/mem/ven_axi_master.sv" "$ROOT/rtl/northbridge/ven_cachemap.sv" \
    "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/verif/l1/axi_slave_bfm.sv" "$ROOT/verif/l1/tb_l1axi_narrow.sv" \
    > "$OBJ/build-cdc.log" 2>&1 \
    || { echo "L1AXINARROW-GATE-FAIL (cdc build)"; tail -40 "$OBJ/build-cdc.log"; exit 1; }

OUT="$("$OBJ/cdc/tb_l1axi_narrow" 2>&1)"
echo "$OUT"
grep -q "L1AXINARROW-GATE-OK" <<<"$OUT" || { echo "L1AXINARROW-GATE-FAIL (cdc)"; exit 1; }

echo "== L1AXI narrow-read (REVIEW_Aug3 C-01) gate PASS =="
