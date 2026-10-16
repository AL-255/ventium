#!/usr/bin/env bash
# No CPU model and no Vivado run: DRP fault BFM plus actual AMD UNISIM MMCM.
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
scratch=/home/yukidama/external/tmp
test "${TMPDIR:?set TMPDIR explicitly}" = "$scratch"
test -w "$scratch"
test "$(stat -c %d "$scratch")" != "$(stat -c %d "$src")"
run="$(mktemp -d "$scratch/ventium-programmable-clock.XXXXXX")"
unisim=/tools/Xilinx/2025.2/Vivado/data/verilog/src
echo "Evidence: $run"
timeout 50s iverilog -g2012 -s tb_pll_ctrl -o "$run/controller.vvp" \
    "$src/tb_pll_ctrl.sv" "$src/ven_pll_ctrl.sv"
timeout 50s vvp "$run/controller.vvp" | tee "$run/controller.log"
timeout 50s iverilog -g2012 -s tb_programmable_clock -s glbl -o "$run/unisim.vvp" \
    "$src/tb_programmable_clock.sv" "$src/ven_pll_ctrl.sv" "$src/ven_programmable_clock.v" \
    "$unisim/unisims/MMCME4_ADV.v" "$unisim/unisims/BUFG.v" \
    "$unisim/unisims/BUFGCE.v" "$unisim/glbl.v"
timeout 50s vvp "$run/unisim.vvp" | tee "$run/unisim.log"
! rg 'Error:|Warning:|FATAL' "$run/controller.log" "$run/unisim.log"
rg -q 'PLL-CTRL-OK' "$run/controller.log"
rg -q 'PROGRAMMABLE-CLOCK-UNISIM-OK' "$run/unisim.log"
sha256sum "$src/ven_pll_ctrl.sv" "$src/ven_programmable_clock.v" \
    "$src/tb_pll_ctrl.sv" "$src/tb_programmable_clock.sv" > "$run/sources.sha256"
