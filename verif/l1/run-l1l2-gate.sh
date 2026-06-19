#!/usr/bin/env bash
# verif/l1/run-l1l2-gate.sh — Phase B integration gate: the L1 + L2 + AXI subsystem
# (ventium_l1_axi built with EN_L2=1, the ven_l2 UltraRAM L2 spliced into ven_l1d's
# backing seam). Builds the self-checking tb_l1l2 with Verilator --binary and asserts
# L1L2-GATE-OK: functional read/write correctness through L1→L2→AXI, an L2 HIT after an
# L1 flush issuing NO new AXI AR, and a dirty-eviction AXI AW write-back — cross-checked
# against ven_l2's perf counters (VEN_DBG_CORE surfaced via VEN_DBG_L2). Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    +define+VEN_DBG_CORE +define+VEN_DBG_L2 \
    --top-module tb_l1l2 -Mdir "$OBJ" -o tb_l1l2 \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/northbridge/ven_cachemap.sv" "$ROOT/rtl/northbridge/ven_l2.sv" \
    "$ROOT/rtl/northbridge/ven_northbridge.sv" "$ROOT/rtl/mem/ventium_l1_axi.sv" \
    "$ROOT/verif/l1/axi_slave_bfm.sv" "$ROOT/verif/l1/tb_l1l2.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L1L2-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1l2" 2>&1)"
echo "$OUT"
grep -q "L1L2-GATE-OK" <<<"$OUT" || { echo "L1L2-GATE-FAIL"; exit 1; }
echo "== L1+L2 integration gate PASS =="
