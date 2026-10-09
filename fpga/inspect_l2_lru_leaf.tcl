# Matched real platform cache; no BD, processor, bitstream or deployment.
if {$argc != 2} {error {usage: inspect_l2_lru_leaf.tcl frozen_inputs fresh_output}}
if {[version -short] ne {2025.2}} {error {unexpected tool version}}
set inputs [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error {fresh output required}}
file mkdir $out
set_param general.maxThreads 1
set receipt [open [file join $out receipt.tsv] {WRONLY CREAT EXCL}]
puts $receipt "profile\tlut_primitives\tregisters\tram_primitives\tworst_slack_ns\tleaf_budget_mhz"
foreach profile {control candidate} {
    create_project -in_memory -part xczu15eg-ffvb1156-2-i l2_leaf
    set defs {SYNTHESIS VEN_ALTSYNCRAM_XPM VEN_L2_STREAM_CWF VEN_L2_STREAM_ANY VEN_VGA_WIDE_STORE VEN_VGA_FULL_STORE_SETUP}
    set_property verilog_define $defs [current_fileset]
    read_verilog -sv [list [file join $inputs ${profile}.v] [file join $inputs prims.sv]]
    synth_design -top l2_cache -mode out_of_context -flatten_hierarchy rebuilt
    create_clock -name leaf_clk -period 25 [get_ports CLK]
    # This is an isolated zero-delay I/O budget, not CPU arrival/load timing.
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
    set path [get_timing_paths -delay_type max -max_paths 1]
    if {[llength $path] != 1} {error {missing constrained timing path}}
    set slack [get_property SLACK $path]
    set equivalent [expr {1000.0/(25.0-$slack)}]
    set logic [llength [get_cells -hier -filter {IS_PRIMITIVE == 1 && REF_NAME =~ LUT*}]]
    set regs [llength [get_cells -hier -filter {IS_PRIMITIVE == 1 && REF_NAME =~ FD*}]]
    set rams [llength [get_cells -hier -filter {IS_PRIMITIVE == 1 && REF_NAME =~ RAM*}]]
    puts $receipt "$profile\t$logic\t$regs\t$rams\t$slack\t$equivalent"
    flush $receipt
    close_project
}
puts $receipt {COMPLETE CPU_FMAX_QUALIFIED=0 STANDARD_SUITE=0}
close $receipt
