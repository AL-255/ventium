#!/usr/bin/env bash
# verif/l1/run-l1nb-gate.sh — Phase C gate: ven_northbridge cacheability routing inside
# ventium_l1_axi (EN_L2=1). Builds the self-checking tb_l1nb with Verilator --binary and
# asserts L1NB-GATE-OK: cacheable DRAM routes through the L2 (hit after L1 flush, no new
# AXI AR), the uncacheable video aperture BYPASSES the L2 and is not L1-cached (a DMA-style
# backing change is seen on the next read; L2 hit/miss counters untouched; bypass counter
# advances), and the uncacheable traffic doesn't evict the cacheable line. Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    +define+VEN_DBG_CORE +define+VEN_DBG_L2 \
    --top-module tb_l1nb -Mdir "$OBJ" -o tb_l1nb \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/rtl/northbridge/ven_l2.sv" \
    "$ROOT/rtl/northbridge/ven_northbridge.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/verif/l1/axi_slave_bfm.sv" "$ROOT/verif/l1/tb_l1nb.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L1NB-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1nb" 2>&1)"
echo "$OUT"
grep -q "L1NB-GATE-OK" <<<"$OUT" || { echo "L1NB-GATE-FAIL"; exit 1; }
echo "== northbridge cacheability-routing gate PASS =="
