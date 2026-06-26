#!/usr/bin/env bash
# verif/l1/run-l1mmio-gate.sh — Phase D.5 gate: the northbridge's second downstream MMIO
# master. ventium_l1_axi EN_L2=1 (+VEN_NB_MMIO) routes uncacheable to_dram=0 device space
# (the VGA aperture) to a separate mmio_* master instead of DDR. Builds tb_l1mmio (DDR slave
# + a distinctly-seeded MMIO target) and asserts L1MMIO-GATE-OK: cacheable DRAM → L2/DDR
# (MMIO untouched); device reads/writes (0xA0000/0xB8000) → MMIO target (no AXI AR/AW, DDR
# unchanged). Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    +define+VEN_NB_MMIO +define+VEN_DBG_CORE +define+VEN_DBG_L2 \
    --top-module tb_l1mmio -Mdir "$OBJ" -o tb_l1mmio \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/rtl/northbridge/ven_l2.sv" \
    "$ROOT/rtl/northbridge/ven_northbridge.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/verif/l1/axi_slave_bfm.sv" "$ROOT/verif/l1/tb_l1mmio.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L1MMIO-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1mmio" 2>&1)"
echo "$OUT"
grep -q "L1MMIO-GATE-OK" <<<"$OUT" || { echo "L1MMIO-GATE-FAIL"; exit 1; }
echo "== northbridge MMIO-master (to_dram split) gate PASS =="
