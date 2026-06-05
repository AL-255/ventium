#!/usr/bin/env bash
# ============================================================================
# run_pit.sh -- standalone build+run for the Ventium M8 8254 PIT device
# (ven_pit). DEDICATED run glue for this device so it does NOT touch the shared
# verif/soc/Makefile (owned/edited by sibling device tasks).
#
#   1. verilator --lint-only   -- ven_pit lints clean as a standalone module
#   2. verilator --binary      -- builds the SV directed unit self-check
#      (tb_ven_pit.sv) vs the documented QEMU 8.2.2 hw/timer/i8254.c +
#      i8254_common.c CPU-observable register semantics, runs it.
#
# Fully isolated: touches ONLY rtl/soc/ven_pit.sv + verif/soc/. Never invokes
# any other rtl/ or verif/ build; never touches rtl/ventium.f.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OBJ="$HERE/obj/pit"
mkdir -p "$OBJ"

VERILATOR="${VERILATOR:-verilator}"
DUT="$ROOT/rtl/soc/ven_pit.sv"
TB="$HERE/tb_ven_pit.sv"

# warnings that are stylistic-only for the *testbench* (DUT is -Wall clean alone)
TB_WAIVERS=(-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-BLKSEQ
            -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-TIMESCALEMOD)

echo "=== [1/2] lint ven_pit (standalone, -Wall) ==="
"$VERILATOR" --lint-only -Wall -Wno-DECLFILENAME --top-module ven_pit "$DUT"
echo "    lint OK"

echo "=== [2/2] build + run directed unit self-check ==="
"$VERILATOR" --binary --assert --timing -Wall "${TB_WAIVERS[@]}" \
  --top-module tb_ven_pit --Mdir "$OBJ" \
  "$DUT" "$TB" -o tb_ven_pit >/dev/null

"$OBJ/tb_ven_pit"
echo "=== run_pit.sh: DONE ==="
