#!/usr/bin/env bash
# run_acpipm.sh — STANDALONE build+run+lint for the Ventium M8 ACPI PM-timer
# device (rtl/soc/ven_acpipm.sv) and its directed unit self-check
# (verif/soc/tb_ven_acpipm.cpp). Self-contained: builds ONLY these two files
# into verif/soc/obj_dir_acpipm/. Does NOT touch rtl/ventium.f or the main build.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DUT="$ROOT/rtl/soc/ven_acpipm.sv"
TB="$HERE/tb_ven_acpipm.cpp"
OBJ="$HERE/obj_dir_acpipm"
VERILATOR="${VERILATOR:-verilator}"

echo "==== verilator --lint-only -Wall (DUT must be clean) ===="
"$VERILATOR" --lint-only -Wall --top-module ven_acpipm "$DUT"
echo "lint: clean"

echo "==== build unit self-check (CLK_HZ=7, PM_TIMER_FREQ=3 via -G) ===="
"$VERILATOR" --cc --exe --build -j 0 \
  -Wall -Wno-fatal \
  --x-assign unique --x-initial unique \
  -GCLK_HZ=7 -GPM_TIMER_FREQ=3 \
  -Mdir "$OBJ" \
  --top-module ven_acpipm \
  "$DUT" "$TB" \
  -o Vven_acpipm

echo "==== run ===="
"$OBJ/Vven_acpipm"
