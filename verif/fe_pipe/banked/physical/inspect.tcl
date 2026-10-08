# Isolated 8-entry versus 64-entry leaf mapping. Never programs a board.
if {$argc != 2} {error {usage: inspect.tcl frozen_inputs fresh_output}}
if {[version -short] ne {2025.2}} {error {unexpected tool version}}
set inputs [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error {fresh output required}}
file mkdir $out
set_param general.maxThreads 1
set receipt [open [file join $out receipt.tcllist] {WRONLY CREAT EXCL}]
foreach profile {control8 banked64} {
    create_project -in_memory -part xczu15eg-ffvb1156-2-i fe_banked_leaf
    read_verilog -sv [file join $inputs ${profile}.sv]
    synth_design -top ven_fe_dtlb -mode out_of_context -flatten_hierarchy rebuilt
    create_clock -name leaf_clk -period 25 [get_ports clk]
    # Explicit zero-delay standalone IO budget, not CPU arrival/load constraints.
    set_input_delay -clock leaf_clk 0 [get_ports -filter {DIRECTION == IN && NAME != clk}]
    set_output_delay -clock leaf_clk 0 [get_ports -filter {DIRECTION == OUT}]
    report_utilization -file [file join $out ${profile}-synth-util.rpt]
    report_ram_utilization -file [file join $out ${profile}-synth-ram.rpt]
    write_verilog -mode funcsim [file join $out ${profile}-synth.v]
    write_checkpoint [file join $out ${profile}-synth.dcp]
    opt_design
    place_design
    route_design
    report_utilization -file [file join $out ${profile}-route-util.rpt]
    report_ram_utilization -file [file join $out ${profile}-route-ram.rpt]
    report_route_status -file [file join $out ${profile}-route-status.rpt]
    report_timing_summary -file [file join $out ${profile}-timing-summary.rpt]
    foreach endpoint {query_valid query_hit query_dirty query_phys query_perm} {
        set outputs [get_ports -quiet ${endpoint}*]
        if {![llength $outputs]} {error "missing $endpoint ports"}
        report_timing -from [get_ports query_page*] -to $outputs -max_paths 1 \
            -file [file join $out ${profile}-${endpoint}.rpt]
    }
    set rams [get_cells -hier -filter {IS_PRIMITIVE == 1 && REF_NAME =~ RAM*}]
    puts $receipt [list PROFILE $profile RAM_PRIMITIVES [llength $rams] CPU_FMAX_QUALIFIED 0]
    foreach cell $rams {
        puts $receipt [list RAM $profile $cell [get_property REF_NAME $cell] [get_property LOC $cell]]
    }
    write_verilog -mode funcsim [file join $out ${profile}-route.v]
    write_checkpoint [file join $out ${profile}-route.dcp]
    flush $receipt
    close_project
}
puts $receipt [list COMPLETE PROFILES 2 CPU_ACCEPTANCE 0]
close $receipt
