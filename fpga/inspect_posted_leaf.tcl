# Isolated real DDR bridge implementations; no BD, bitstream or board access.
if {$argc != 2} {error {usage: inspect_posted_leaf.tcl frozen_inputs fresh_output}}
if {[version -short] ne {2025.2}} {error {unexpected tool version}}
set inputs [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error {fresh output required}}
file mkdir $out
set_param general.maxThreads 1
set receipt [open [file join $out receipt.tsv] {WRONLY CREAT EXCL}]
puts $receipt "profile\tlogic_luts\tregisters\tram_primitives\tworst_slack_ns\tleaf_budget_mhz"
foreach profile {serial posted4 posted8 posted16} {
    create_project -in_memory -part xczu15eg-ffvb1156-2-i bridge_leaf
    if {$profile eq {serial}} {
        read_verilog -sv [file join $inputs serial.v]
        synth_design -top ven_ddram_axi -mode out_of_context -flatten_hierarchy rebuilt
    } else {
        read_verilog -sv [file join $inputs posted.sv]
        set slots [string range $profile 6 end]
        synth_design -top ven_ddram_axi_posted -generic WRITE_SLOTS=$slots \
            -mode out_of_context -flatten_hierarchy rebuilt
    }
    create_clock -name leaf_clk -period 25 [get_ports clk]
    # Zero-delay standalone I/O budget is NOT the enclosing CPU arrival/load.
    set_input_delay -clock leaf_clk 0 [get_ports -filter {DIRECTION == IN && NAME != clk}]
    set_output_delay -clock leaf_clk 0 [get_ports -filter {DIRECTION == OUT}]
    report_utilization -file [file join $out ${profile}-synth-util.rpt]
    report_ram_utilization -file [file join $out ${profile}-synth-ram.rpt]
    write_verilog -mode funcsim [file join $out ${profile}-synth.v]
    opt_design
    place_design
    route_design
    report_utilization -file [file join $out ${profile}-route-util.rpt]
    report_ram_utilization -file [file join $out ${profile}-route-ram.rpt]
    report_route_status -file [file join $out ${profile}-route-status.rpt]
    report_timing_summary -file [file join $out ${profile}-timing.rpt]
    report_timing -max_paths 10 -file [file join $out ${profile}-paths.rpt]
    write_verilog -mode funcsim [file join $out ${profile}-route.v]
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
