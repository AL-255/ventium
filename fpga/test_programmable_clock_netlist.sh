#!/usr/bin/env bash
set -euo pipefail
test "$#" = 2
test -n "${TMPDIR:?}"
# Vivado exports its bundled C++ runtime, which is older than the host Icarus
# binary's ABI. Keep the vendor environment in Vivado, not in this native child.
unset LD_LIBRARY_PATH LD_PRELOAD
src="$(cd "$(dirname "$0")" && pwd)"
unisim=/tools/Xilinx/2025.2/Vivado/data/verilog/src/unisims
netlist="$1"
output="$2"
test ! -e "$output.vvp"
timeout 50s iverilog -g2012 -s tb_programmable_clock_netlist -s glbl \
    -y "$unisim" -o "$output.vvp" "$src/tb_programmable_clock_netlist.sv" "$netlist"
timeout 50s vvp "$output.vvp" | tee "$output.log"
! /usr/bin/grep -E 'Error:|Warning:|FATAL' "$output.log"
/usr/bin/grep -q 'PROGRAMMABLE-CLOCK-NETLIST-OK' "$output.log"
