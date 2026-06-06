#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# ============================================================================
# run_i8042.sh -- standalone build+run for the Ventium M8 i8042 PS/2 keyboard
# controller device (ven_i8042). DEDICATED run glue for this device so it does
# NOT touch the shared verif/soc/Makefile (owned/edited by sibling device tasks).
#
#   1. verilator --lint-only   -- ven_i8042 lints clean as a standalone module
#   2. verilator --binary      -- builds the SV directed unit self-check
#      (tb_ven_i8042.sv) vs the documented QEMU 8.2.2 hw/input/pckbd.c register
#      semantics, runs it.
#
# Fully isolated: touches ONLY rtl/soc/ven_i8042.sv + verif/soc/. Never invokes
# any other rtl/ or verif/ build; never touches rtl/ventium.f.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OBJ="$HERE/obj/i8042"
mkdir -p "$OBJ"

VERILATOR="${VERILATOR:-verilator}"
DUT="$ROOT/rtl/soc/ven_i8042.sv"
TB="$HERE/tb_ven_i8042.sv"

# warnings that are stylistic-only for the *testbench* (DUT is -Wall clean alone)
TB_WAIVERS=(-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-BLKSEQ
            -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-TIMESCALEMOD)

echo "=== [1/2] lint ven_i8042 (standalone, -Wall) ==="
"$VERILATOR" --lint-only -Wall -Wno-DECLFILENAME --top-module ven_i8042 "$DUT"
echo "    lint OK"

echo "=== [2/2] build + run directed unit self-check ==="
"$VERILATOR" --binary --assert --timing -Wall "${TB_WAIVERS[@]}" \
  --top-module tb_ven_i8042 --Mdir "$OBJ" \
  "$DUT" "$TB" -o tb_ven_i8042 >/dev/null

"$OBJ/tb_ven_i8042"
echo "=== run_i8042.sh: DONE ==="
