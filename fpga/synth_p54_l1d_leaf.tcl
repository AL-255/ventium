# Bounded leaf synthesis probe for the P54 D-cache storage geometry.
# Invoke only through fpga/run_vivado_exclusive.sh, with an outer timeout.
# This does not close top-level timing or establish gameplay performance.
if {[llength $argv] != 2} {
    error "usage: -tclargs packed|banked|banked_shared0|paired|code_buffer|code_stream|code_stream_reuse|code_stream_reuse_shared0 OUTPUT_DIRECTORY"
}
set variant [lindex $argv 0]
set output_dir [file normalize [lindex $argv 1]]
set repo [file normalize [file join [file dirname [info script]] ..]]
set_param general.maxThreads 1
set defines {}
switch -- $variant {
    packed {}
    banked {set defines {VEN_L1D_BANKED_DATA}}
    banked_shared0 {set defines {VEN_L1D_BANKED_DATA VEN_L1D_BANK0_SHARED_XLINE}}
    paired {set defines {VEN_L1D_BANKED_DATA VEN_P54_DUAL_HIT}}
    code_buffer {set defines {VEN_L1D_BANKED_DATA VEN_L1D_CODE_BUFFER}}
    code_stream {set defines {VEN_L1D_BANKED_DATA VEN_L1D_CODE_BUFFER VEN_L1D_CODE_STREAM}}
    code_stream_reuse {set defines {VEN_L1D_BANKED_DATA VEN_L1D_CODE_BUFFER VEN_L1D_CODE_STREAM VEN_L1D_WINDOW_REUSE}}
    code_stream_reuse_shared0 {set defines {VEN_L1D_BANKED_DATA VEN_L1D_CODE_BUFFER VEN_L1D_CODE_STREAM VEN_L1D_WINDOW_REUSE VEN_L1D_BANK0_SHARED_XLINE}}
    default {error "unknown variant $variant"}
}
file mkdir $output_dir
set sources [list \
    [file join $repo rtl/mem/ven_p54_bank_arb.sv] \
    [file join $repo rtl/mem/ven_p54_hit_return.sv] \
    [file join $repo rtl/mem/ven_l1d.sv]]
read_verilog -sv $sources
set synth_args [list -top ven_l1d -part xck26-sfvc784-2LV-c \
    -mode out_of_context -flatten_hierarchy none]
foreach define $defines {lappend synth_args -verilog_define $define}
synth_design {*}$synth_args
create_clock -name core_clk -period 22.222 [get_ports clk]
report_utilization -hierarchical -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_synth.rpt]
write_checkpoint -force [file join $output_dir ven_l1d.dcp]
puts "P54-L1D-LEAF-SYNTH-OK variant=$variant output=$output_dir"
