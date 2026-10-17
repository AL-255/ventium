#!/usr/bin/env bash
set -euo pipefail
test "$#" = 2
test -n "${TMPDIR:?}"
src="$(cd "$(dirname "$0")" && pwd)"
unisim=/tools/Xilinx/2025.2/Vivado/data/verilog/src/unisims
netlist="$1"
output="$2"
test ! -e "$output.vvp"
timeout 50s iverilog -g2012 -s tb_programmable_clock_netlist -s glbl \
    -y "$unisim" -o "$output.vvp" "$src/tb_programmable_clock_netlist.sv" "$netlist"
timeout 50s vvp "$output.vvp" | tee "$output.log"
! rg 'Error:|Warning:|FATAL' "$output.log"
rg -q 'PROGRAMMABLE-CLOCK-NETLIST-OK' "$output.log"
