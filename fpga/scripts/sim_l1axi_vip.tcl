# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# fpga/scripts/sim_l1axi_vip.tcl — simulate ventium_l1_axi against the REAL Xilinx
# Zynq US+ PS8 VIP (design_l1axi BD) in xsim, replaying the on-silicon cold-line
# fetch fill pattern (verif/l1/tb_l1axi_vip.sv). The PS8 VIP enforces AXI4 on-wire,
# so a back-to-back / cold-line fill burst the behavioral slave tolerates surfaces
# here as a protocol assertion or returned-data corruption (the F4 Quake fetch wedge).
#
# Run (vivado NOT on PATH):
#   source /tools/Xilinx/2025.2/Vivado/settings64.sh
#   vivado -mode batch -source fpga/scripts/sim_l1axi_vip.tcl

set ROOT [file normalize [file dirname [info script]]/../..]
set PROJ $ROOT/fpga/build/l1axi/proj/ventium_l1axi.xpr

open_project $PROJ

# bring the tb into the sim fileset; do NOT carry the synth-only SYNTHESIS define
# (keep the RTL elaboration guards + bound SVA live for extra on-wire checking).
add_files -fileset sim_1 -norecurse $ROOT/verif/l1/tb_l1axi_vip.sv
set_property verilog_define {} [get_filesets sim_1]
set_property top tb_l1axi_vip [get_filesets sim_1]
update_compile_order -fileset sim_1

# generate the BD simulation target (PS8 VIP sim model + BD sim wrapper)
set bd [get_files -quiet *design_l1axi.bd]
if {$bd ne ""} { generate_target simulation [get_files $bd] }

# run to $finish, capture everything
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

launch_simulation -mode behavioral
puts "SIM_L1AXI_VIP_DONE"
