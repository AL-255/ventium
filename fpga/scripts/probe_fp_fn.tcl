# =====================================================================
# Per-function FP datapath area probe. Synthesizes ONE wrapper top from
# fpga/scripts/fp_fn_probes.sv (registered I/O around a single fpu_x87_pkg
# function) OOC, to measure that function's combinational cone (LUT/CARRY8/DSP).
#
# Run:  vivado -mode batch -source fpga/scripts/probe_fp_fn.tcl -notrace -tclargs <top>
#   <top> in {probe_fx_add probe_fx_mul probe_fx_round probe_fx_toint probe_fx_bcdtofx}
# =====================================================================
set TOP [lindex $argv 0]
if {$TOP eq ""} { set TOP probe_fx_add }

set ROOT [pwd]
if {![file exists $ROOT/rtl/fpu/fpu_x87_pkg.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/probe_fp_$TOP
file mkdir $OUT
set PART xck26-sfvc784-2LV-c

puts "PROBE(fp-fn $TOP): ROOT=$ROOT PART=$PART"
create_project -in_memory -part $PART probe_fp_$TOP

# packages the FP pkg may rely on (read in ventium.f order), then the pkg + probes
foreach f {ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv \
           fpu/fpu_x87_pkg.sv} {
    read_verilog -sv $RTL/$f
}
read_verilog -sv $ROOT/fpga/scripts/fp_fn_probes.sv

set xdc $OUT/clk.xdc
set fh [open $xdc w]
puts $fh "create_clock -period 10.000 -name clk \[get_ports clk\]"
close $fh
read_xdc $xdc

puts "PROBE(fp-fn $TOP): synth_design starting ..."
synth_design -top $TOP -part $PART -mode out_of_context -flatten_hierarchy rebuilt

report_utilization -file $OUT/util.rpt
report_timing_summary -max_paths 4 -delay_type max -file $OUT/timing_summary.rpt
puts "PROBE_FP_FN_DONE $TOP"
