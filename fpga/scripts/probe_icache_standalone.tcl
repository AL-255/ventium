# =====================================================================
# Standalone icache area probe — measure the icache MODULE's own cost
# (storage + read-mux), isolated from the core's decode windows, to decide
# whether a registered-BRAM conversion is worth the front-end pipeline rework.
# Synthesizes rtl/mem/icache.sv (async distributed-RAM, as-is) OOC.
#
# Run:  vivado -mode batch -source fpga/scripts/probe_icache_standalone.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/mem/icache.sv] && [file exists [file join [file dirname [info script]] .. .. rtl/mem/icache.sv]]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/probe_icache_async
file mkdir $OUT
set PART xck26-sfvc784-2LV-c

puts "PROBE(icache-async): ROOT=$ROOT PART=$PART"
create_project -in_memory -part $PART probe_icache_async
read_verilog -sv $RTL/mem/icache.sv

set xdc $OUT/clk.xdc
set fh [open $xdc w]
puts $fh "create_clock -period 10.000 -name clk \[get_ports clk\]"
close $fh
read_xdc $xdc

puts "PROBE(icache-async): synth_design starting ..."
synth_design -top icache -part $PART -mode out_of_context -flatten_hierarchy rebuilt

report_utilization -file $OUT/util.rpt
report_timing_summary -max_paths 5 -delay_type max -file $OUT/timing_summary.rpt
puts "PROBE_ICACHE_ASYNC_DONE"
