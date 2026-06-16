# =====================================================================
# Standalone UltraRAM-utilization probe for ven_l2 (the L2 cache controller).
# Settles the load-bearing claim: does the default 2 MiB / 32 B-line / 8-way ven_l2
# DATA array infer the FULL UltraRAM column complement on the KV260 part — i.e. all
# 64 URAM288 blocks (4 wide × 16 deep, 256 data bits + 32 spare parity/word) — with the tags
# + {valid,dirty} + PLRU in BRAM? Synthesizes rtl/mem/ven_l2.sv OOC and reports
# URAM + RAMB utilization + timing.
#
# Expected (xck26-sfvc784): URAM288 = 64 (100% of the device), RAMB36 ≈ 30 (the
# ~1.1 Mb packed-per-set meta), and the data read mux DISSOLVED into the URAM (no
# distributed-RAM blow-up). A URAM count of 64 is the proof of "uses all the UltraRAM".
#
# Run:  vivado -mode batch -source fpga/scripts/probe_l2_uram.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/mem/ven_l2.sv] && [file exists [file join [file dirname [info script]] .. .. rtl/mem/ven_l2.sv]]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/probe_l2_uram
file mkdir $OUT
set PART xck26-sfvc784-2LV-c

puts "PROBE(l2-uram): ROOT=$ROOT PART=$PART"
create_project -in_memory -part $PART probe_l2_uram
read_verilog -sv $RTL/mem/ven_l2.sv

set xdc $OUT/clk.xdc
set fh [open $xdc w]
# the L2 hides DDR latency, so it is not on the critical Fmax path; constrain modestly.
puts $fh "create_clock -period 10.000 -name clk \[get_ports clk\]"
close $fh
read_xdc $xdc

puts "PROBE(l2-uram): synth_design starting (default 2 MiB / 8-way config) ..."
synth_design -top ven_l2 -part $PART -mode out_of_context -flatten_hierarchy rebuilt

report_utilization -file $OUT/util.rpt
report_timing_summary -max_paths 5 -delay_type max -file $OUT/timing_summary.rpt

# echo the headline block-RAM numbers to stdout for a quick read.
set uram [llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]]
set bram [llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.*}]]
puts "PROBE_L2_URAM_RESULT: URAM288=$uram  RAMB=$bram  (expect URAM288=64)"
puts "PROBE_L2_URAM_DONE"
