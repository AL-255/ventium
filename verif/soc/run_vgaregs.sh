#!/usr/bin/env bash
# ============================================================================
# run_vgaregs.sh -- standalone build+run for the Ventium M8 VGA register file
# device (ven_vgaregs). DEDICATED run glue for this device so it does NOT touch
# the shared verif/soc/Makefile (owned/edited by sibling device tasks).
#
#   1. verilator --lint-only   -- ven_vgaregs lints clean as a standalone module
#   2. verilator --binary      -- builds the SV directed unit self-check
#      (tb_ven_vgaregs.sv) vs the documented QEMU 8.2.2 register semantics, runs.
#
# Fully isolated: touches ONLY rtl/soc/ven_vgaregs.sv + verif/soc/. Never invokes
# any other rtl/ or verif/ build; never touches rtl/ventium.f.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OBJ="$HERE/obj/vgaregs"
mkdir -p "$OBJ"

VERILATOR="${VERILATOR:-verilator}"
DUT="$ROOT/rtl/soc/ven_vgaregs.sv"
TB="$HERE/tb_ven_vgaregs.sv"

# warnings that are stylistic-only for the *testbench* (DUT is -Wall clean alone)
TB_WAIVERS=(-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-BLKSEQ
            -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-TIMESCALEMOD)

echo "=== [1/2] lint ven_vgaregs (standalone, -Wall) ==="
"$VERILATOR" --lint-only -Wall -Wno-DECLFILENAME --top-module ven_vgaregs "$DUT"
echo "    lint OK"

echo "=== [2/2] build + run directed unit self-check ==="
"$VERILATOR" --binary --assert --timing -Wall "${TB_WAIVERS[@]}" \
  --top-module tb_ven_vgaregs --Mdir "$OBJ" \
  "$DUT" "$TB" -o tb_ven_vgaregs >/dev/null

"$OBJ/tb_ven_vgaregs"
echo "=== run_vgaregs.sh: DONE ==="
