#!/usr/bin/env bash
# verif/l1/run-l1axi-wd-gate.sh — #34 AXI watchdog directed gate. ventium_l1_axi at a
# SMALL WATCHDOG against a STUCK AXI slave: a core read and a core write must each
# raise bus_err (the watchdog fired) within the bound, with the AXI handshake HELD
# (no protocol-violating retract) and NO fake c_ack. Asserts L1AXIWD-GATE-OK. The
# complement (no false-fire under a normal slave) is covered by run-l1axi-gate.sh /
# run-l1axi-verify.sh at the default WATCHDOG=1024.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT

verilator --binary -sv --assert -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC --top-module tb_l1axi_wd -Mdir "$OBJ" -o tb_l1axi_wd \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/mem/ventium_l1_axi.sv" "$ROOT/verif/l1/axi_slave_bfm.sv" \
    "$ROOT/verif/l1/tb_l1axi_wd.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L1AXIWD-GATE-FAIL (build)"; tail -25 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1axi_wd" 2>&1)"
echo "$OUT" | grep -vE "^- |Verilator:"
grep -q "L1AXIWD-GATE-OK" <<<"$OUT" || { echo "L1AXIWD-GATE-FAIL"; exit 1; }
echo "== L1AXI watchdog gate PASS =="
