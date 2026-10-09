# Matched platform L2 only. The P5 L1s, CPU and board are not instantiated.
if {$argc != 2} {error {usage: inspect_l2_capacity_leaf.tcl inputs fresh_output}}
if {[version -short] ne {2025.2}} {error {unexpected tool version}}
set inputs [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error {fresh output required}}
file mkdir $out
set_param general.maxThreads 1
set receipt [open [file join $out receipt.tsv] {WRONLY CREAT EXCL}]
puts $receipt "profile\tlut_primitives\tregisters\tbram36\tbram18\tsetup_slack_ns\thold_slack_ns\tleaf_budget_mhz"
foreach profile {control default128 sets1024} {
    create_project -in_memory -part xczu15eg-ffvb1156-2-i l2_capacity_leaf
    set defs {SYNTHESIS VEN_ALTSYNCRAM_XPM VEN_L2_STREAM_CWF VEN_L2_STREAM_ANY VEN_VGA_WIDE_STORE VEN_VGA_FULL_STORE_SETUP}
    set_property verilog_define $defs [current_fileset]
    set source [expr {$profile eq {control} ? {control.v} : {candidate.v}}]
    read_verilog -sv [list [file join $inputs $source] [file join $inputs prims.sv]]
    set generics {}
    if {$profile eq {sets1024}} {set generics {-generic CACHE_SETS=1024}}
    synth_design -top l2_cache -mode out_of_context -flatten_hierarchy rebuilt {*}$generics
    create_clock -name leaf_clk -period 25 [get_ports CLK]
    # Identical zero-delay leaf budget. NOT full-chip timing or sign-off.
    set_input_delay -clock leaf_clk 0 [get_ports -filter {DIRECTION == IN && NAME != CLK}]
    set_output_delay -clock leaf_clk 0 [get_ports -filter {DIRECTION == OUT}]
    report_utilization -file [file join $out ${profile}-synth-util.rpt]
    report_ram_utilization -file [file join $out ${profile}-synth-ram.rpt]
    opt_design
    place_design
    route_design
    report_utilization -file [file join $out ${profile}-route-util.rpt]
    report_ram_utilization -file [file join $out ${profile}-route-ram.rpt]
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
    set bram36 [llength [get_cells -hier -filter {IS_PRIMITIVE == 1 && REF_NAME =~ RAMB36*}]]
    set bram18 [llength [get_cells -hier -filter {IS_PRIMITIVE == 1 && REF_NAME =~ RAMB18*}]]
    puts $receipt "$profile\t$logic\t$regs\t$bram36\t$bram18\t$setup\t$hold\t$mhz"
    flush $receipt
    close_project
}
puts $receipt {COMPLETE CPU_FMAX_QUALIFIED=0 STANDARD_SUITE=0}
close $receipt
