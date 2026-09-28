# Matched out-of-context register-to-register decoder area/timing comparison.
# This is not routed core timing. Invoke through run_vivado_exclusive.sh.
if {[llength $argv] != 2} {
    error "usage: -tclargs control|mem_alu OUTPUT_DIRECTORY"
}
set variant [lindex $argv 0]
set output_dir [file normalize [lindex $argv 1]]
set repo [file normalize [file join [file dirname [info script]] ..]]
set defines {VTM_NO_DPI VEN_FAST_MEM_ADD}
switch -- $variant {
    control {}
    mem_alu {lappend defines VEN_FAST_MEM_ALU}
    default {error "unknown variant $variant"}
}
file mkdir $output_dir
read_verilog -sv [list \
    [file join $repo rtl/ventium_pkg.sv] \
    [file join $repo rtl/core/ventium_alu_pkg.sv] \
    [file join $repo rtl/core/ventium_decode_pkg.sv] \
    [file join $repo rtl/core/decode.sv] \
    [file join $repo fpga/p54_decode_probe.sv]]
set synth_args [list -top p54_decode_probe -part xck26-sfvc784-2LV-c \
    -mode out_of_context -flatten_hierarchy none]
foreach define $defines {lappend synth_args -verilog_define $define}
synth_design {*}$synth_args
create_clock -name core_clk -period 22.222 [get_ports clk]
report_utilization -hierarchical -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_synth.rpt]
write_checkpoint -force [file join $output_dir p54_decode_probe.dcp]
puts "P54-DECODE-PROBE-OK variant=$variant output=$output_dir"
