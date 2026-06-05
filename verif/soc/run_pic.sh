#!/usr/bin/env bash
# run_pic.sh — STANDALONE build+run+lint for the Ventium M8 8259A PIC device
# (rtl/soc/ven_pic.sv) and its directed unit self-check
# (verif/soc/tb_ven_pic.cpp). Self-contained: builds ONLY these two files into
# verif/soc/obj_dir_pic/. Does NOT touch rtl/ventium.f or the main build.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DUT="$ROOT/rtl/soc/ven_pic.sv"
TB="$HERE/tb_ven_pic.cpp"
OBJ="$HERE/obj_dir_pic"
VERILATOR="${VERILATOR:-verilator}"

echo "==== verilator --lint-only -Wall (DUT must be clean) ===="
"$VERILATOR" --lint-only -Wall --top-module ven_pic "$DUT"
echo "lint: clean"

echo "==== build unit self-check ===="
"$VERILATOR" --cc --exe --build -j 0 \
  -Wall -Wno-fatal \
  --x-assign unique --x-initial unique \
  -Mdir "$OBJ" \
  --top-module ven_pic \
  "$DUT" "$TB" \
  -o Vven_pic

echo "==== run ===="
"$OBJ/Vven_pic"
