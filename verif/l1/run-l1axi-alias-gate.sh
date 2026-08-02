#!/usr/bin/env bash
# verif/l1/run-l1axi-alias-gate.sh
# SMALL WATCHDOG against a STUCK AXI slave: a core read and a core write must each
# raise bus_err (the watchdog fired) within the bound, with the AXI handshake HELD
# (no protocol-violating retract) and NO fake c_ack. Asserts L1AXIALIAS-GATE-OK. The
# complement (no false-fire under a normal slave) is covered by run-l1axi-gate.sh /
# run-l1axi-verify.sh at the default WATCHDOG=1024.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT

verilator --binary -sv --assert -Wno-UNUSED -Wno-DECLFILENAME -Wno-INITIALDLY \
    -Wno-IMPLICITSTATIC --top-module tb_l1axi_alias -Mdir "$OBJ" -o tb_l1axi_alias \
    "$ROOT/rtl/mem/ven_l1d.sv" "$ROOT/rtl/mem/ven_axi_master.sv" \
    "$ROOT/rtl/mem/ventium_l1_axi.sv" "$ROOT/verif/l1/axi_slave_bfm.sv" \
    "$ROOT/verif/l1/tb_l1axi_alias.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "L1AXIALIAS-GATE-FAIL (build)"; tail -25 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_l1axi_alias" 2>&1)"
echo "$OUT" | grep -vE "^- |Verilator:" | grep -v "M-07 ALIAS"

# The gate asserts on the ALIAS DETECTOR, not on bus_err. Measured reason: bus_err is
# raised by several mechanisms (the watchdog fires too when a rejected request never
# completes), so for 0x0FFFFFFE it reads 1 even with the extent check removed -- an
# assertion on bus_err would have passed in both directions and proved nothing. The
# set of addresses the detector actually rejects IS discriminating:
#     without the extent check : {10000000}
#     with it                  : {0ffffffe, 10000000}
ADDRS="$(sed -n 's/.*ALIAS: addr=\([0-9a-f]*\).*/\1/p' <<<"$OUT" | sort -u | tr '\n' ' ')"
echo "  alias-rejected addresses: ${ADDRS:-<none>}"
fail=0
grep -q "10000000" <<<"$ADDRS" || { echo "  FAIL: first-byte-outside case was NOT rejected"; fail=1; }
grep -q "0ffffffe" <<<"$ADDRS" || { echo "  FAIL: REVIEW1_Aug2 H-04 -- an access whose EXTENT crosses out of"; \
                                    echo "        ADDR_MASK was accepted; its second beat wraps to the carveout base"; fail=1; }
grep -q "00001000" <<<"$ADDRS" && { echo "  FAIL: the in-window control was rejected (check is over-broad)"; fail=1; }
[ "$fail" = 0 ] || { echo "L1AXIALIAS-GATE-FAIL"; exit 1; }
grep -q "L1AXIALIAS-GATE-OK" <<<"$OUT" || { echo "L1AXIALIAS-GATE-FAIL (tb)"; exit 1; }
echo "== L1AXI alias-extent gate PASS =="
