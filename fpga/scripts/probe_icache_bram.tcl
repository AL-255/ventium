# =====================================================================
# Standalone icache BRAM-inference probe (+VEN_IC_BRAM). Settles the make-or-break
# question the P0-3 rejection left open with the WRONG technique: does forcing the
# replicated, registered-read line store into RAMB36 actually infer Block RAM and
# DISSOLVE the distributed-RAM 256:1 read-mux MUXF (the placed congestion root)?
# Synthesizes rtl/mem/icache.sv OOC with +VEN_IC_BRAM; reports RAMB36 + MUXF.
#
# Run:  vivado -mode batch -source fpga/scripts/probe_icache_bram.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/mem/icache.sv] && [file exists [file join [file dirname [info script]] .. .. rtl/mem/icache.sv]]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/probe_icache_bram
file mkdir $OUT
set PART xck26-sfvc784-2LV-c

puts "PROBE(icache-bram): ROOT=$ROOT PART=$PART"
create_project -in_memory -part $PART probe_icache_bram
read_verilog -sv $RTL/mem/icache.sv

set xdc $OUT/clk.xdc
set fh [open $xdc w]
puts $fh "create_clock -period 10.000 -name clk \[get_ports clk\]"
close $fh
read_xdc $xdc

puts "PROBE(icache-bram): synth_design starting ..."
synth_design -top icache -part $PART -mode out_of_context -flatten_hierarchy rebuilt \
    -verilog_define {VEN_IC_BRAM}

report_utilization -file $OUT/util.rpt
report_timing_summary -max_paths 5 -delay_type max -file $OUT/timing_summary.rpt
puts "PROBE_ICACHE_BRAM_DONE"
