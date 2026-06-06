#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# ============================================================================
# verif/soc/run_rtc.sh -- standalone build+run of the ven_rtc (M8 RTC/CMOS)
# directed unit self-check.
#
# ISOLATION: builds ONLY rtl/soc/ven_rtc.sv + verif/soc/tb_ven_rtc.sv into a
# private obj dir. Touches no rtl/ventium.f, no core/bus/top, no other device.
# Self-contained (no ventium_pkg). Independent of the main Ventium build.
#
#   ./run_rtc.sh         -- lint (-Wall clean) + build + run the self-check
#   ./run_rtc.sh lint    -- lint only
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VERILATOR="${VERILATOR:-verilator}"

DUT="$ROOT/rtl/soc/ven_rtc.sv"
TB="$HERE/tb_ven_rtc.sv"
OBJ="$HERE/obj_dir_rtc"
TOP="tb_ven_rtc"

echo "==== ven_rtc: verilator --lint-only -Wall ===="
"$VERILATOR" --lint-only -Wall -Wno-DECLFILENAME --top-module ven_rtc "$DUT"
echo "lint: clean"

if [[ "${1:-}" == "lint" ]]; then
  exit 0
fi

# testbench-only stylistic waivers (the DUT is -Wall clean on its own)
TB_WAIVERS=(-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-BLKSEQ
            -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-TIMESCALEMOD
            -Wno-CASEINCOMPLETE)

echo "==== ven_rtc: build self-check (verilator --binary --timing) ===="
"$VERILATOR" --binary --timing -Wall "${TB_WAIVERS[@]}" \
  --top-module "$TOP" --Mdir "$OBJ" "$DUT" "$TB" -o "$TOP"

echo "==== ven_rtc: run self-check ===="
"$OBJ/$TOP"
