# Matched bridge-only check. No CPU, BD, bitstream or deployment.
if {$argc != 2} {error {usage: inspect_axi_read_through_leaf.tcl inputs fresh_output}}
if {[version -short] ne {2025.2}} {error {unexpected tool version}}
set inputs [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error {fresh output required}}
file mkdir $out
set_param general.maxThreads 1
set receipt [open [file join $out receipt.tsv] {WRONLY CREAT EXCL}]
puts $receipt "profile\tlut_primitives\tregisters\tsetup_slack_ns\thold_slack_ns\tleaf_budget_mhz"
foreach profile {control off on} {
    create_project -in_memory -part xczu15eg-ffvb1156-2-i axi_read_leaf
    set defs {SYNTHESIS VEN_AXI2AVL_BPIPE VEN_AXI2AVL_WRITE_THROUGH}
    if {$profile eq {on}} {lappend defs VEN_AXI2AVL_READ_THROUGH}
    set_property verilog_define $defs [current_fileset]
    set source [expr {$profile eq {control} ? {control.sv} : {candidate.sv}}]
    read_verilog -sv [file join $inputs $source]
    synth_design -top ven_axi2avalon -mode out_of_context -flatten_hierarchy rebuilt
    create_clock -name leaf_clk -period 25 [get_ports clk]
    set_input_delay -clock leaf_clk 0 [get_ports -filter {DIRECTION == IN && NAME != clk}]
    set_output_delay -clock leaf_clk 0 [get_ports -filter {DIRECTION == OUT}]
    report_utilization -file [file join $out ${profile}-synth-util.rpt]
    opt_design
    place_design
    route_design
    report_utilization -file [file join $out ${profile}-route-util.rpt]
    report_route_status -file [file join $out ${profile}-route-status.rpt]
    report_timing_summary -file [file join $out ${profile}-timing.rpt]
    report_timing -max_paths 10 -file [file join $out ${profile}-paths.rpt]
    write_checkpoint [file join $out ${profile}-route.dcp]
    set setup_path [get_timing_paths -delay_type max -max_paths 1]
    set hold_path [get_timing_paths -delay_type min -max_paths 1]
    if {[llength $setup_path] != 1 || [llength $hold_path] != 1} {error {missing constrained timing path}}
    set setup [get_property SLACK $setup_path]
    set hold [get_property SLACK $hold_path]
    set mhz [expr {1000.0/(25.0-$setup)}]
    set logic [llength [get_cells -hier -filter {IS_PRIMITIVE == 1 && REF_NAME =~ LUT*}]]
    set regs [llength [get_cells -hier -filter {IS_PRIMITIVE == 1 && REF_NAME =~ FD*}]]
    puts $receipt "$profile\t$logic\t$regs\t$setup\t$hold\t$mhz"
    flush $receipt
    close_project
}
puts $receipt {COMPLETE CPU_FMAX_QUALIFIED=0 STANDARD_SUITE=0}
close $receipt
