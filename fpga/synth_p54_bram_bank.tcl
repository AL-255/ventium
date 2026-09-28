# Out-of-context FPGA primitive feasibility only; no core integration claim.
if {[llength $argv] != 1} {
    error "usage: -tclargs OUTPUT_DIRECTORY"
}
set output_dir [file normalize [lindex $argv 0]]
set repo [file normalize [file join [file dirname [info script]] ..]]
file mkdir $output_dir
read_verilog -sv [file join $repo rtl/mem/ven_p54_bram_bank.sv]
synth_design -top ven_p54_bram_bank -part xck26-sfvc784-2LV-c \
    -mode out_of_context -flatten_hierarchy none
create_clock -name core_clk -period 22.222 [get_ports clk]
report_utilization -hierarchical -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing_synth.rpt]
write_checkpoint -force [file join $output_dir ven_p54_bram_bank.dcp]
puts "P54-BRAM-BANK-SYNTH-OK output=$output_dir"
