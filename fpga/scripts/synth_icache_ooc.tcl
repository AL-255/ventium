# fpga/scripts/synth_icache_ooc.tcl — OOC-synthesize the icache to a funcsim netlist
# for gate-level sim of the residual board-only fetch READ corruption (the jae-operand
# corruption beyond the fixed declone/collision). Matches the hpc40ft icache geometry
# (VEN_IC_BRAM + VEN_CACHE_HALF = 128 sets x 2 ways, RAMB36 line store).
#   /tools/Xilinx/2025.2/Vivado/bin/vivado -mode batch -source fpga/scripts/synth_icache_ooc.tcl
set ROOT [file normalize [file dirname [info script]]/../..]
set OUT  $ROOT/fpga/build/icache_ooc
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART ic_ooc
read_verilog -sv $ROOT/rtl/ventium_pkg.sv
read_verilog -sv $ROOT/rtl/mem/icache.sv
read_verilog -sv $ROOT/verif/icache_gls/ic_gls_wrap.sv
synth_design -top ic_gls_wrap -part $PART -mode out_of_context \
    -verilog_define {VTM_NO_DPI VEN_IC_BRAM VEN_CACHE_HALF}
report_utilization -file $OUT/util.rpt
write_verilog -force -mode funcsim $OUT/icache_funcsim.v
write_verilog -force -mode design  $OUT/icache_synth.v
puts "ICACHE_OOC_DONE -> $OUT/icache_funcsim.v"
