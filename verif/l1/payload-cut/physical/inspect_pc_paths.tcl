# Isolated real-cache A/B; zero input/output delay is a local port budget,
# NOT the CPU's query-arrival time, CPU Fmax, or FPGA acceptance.
if {$argc != 1} {error {usage: inspect_pc_paths.tcl fresh_output}}
if {[version -short] ne {2025.2}} {error {tool identity}}
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error {fresh output required}}
file mkdir $out
set root [file dirname [file normalize [info script]]]
set handle [open $root/exact110.defines.args.txt r]
set args [split [string trim [read $handle]]]
close $handle
set defs {SYNTHESIS VTM_NO_DPI}
foreach arg $args {
    if {![string match {+define+*} $arg]} {error "bad definition $arg"}
    lappend defs [string range $arg 8 end]
}
if {[llength $defs] != 112} {error {wrong source profile}}
set receipt [open [file join $out receipt.tcllist] {WRONLY CREAT EXCL}]
set_param general.maxThreads 1
foreach profile {control repair} {
    create_project -in_memory -part xczu15eg-ffvb1156-2-i payload_probe
    set_property verilog_define $defs [current_fileset]
    read_verilog -sv [list $root/ven_p54_bank_arb.sv $root/ven_p54_hit_return.sv $root/$profile.sv]
    synth_design -top ven_l1d -mode out_of_context -flatten_hierarchy rebuilt
    create_clock -name probe_clk -period 25 [get_ports clk]
    set_input_delay 0 -clock probe_clk [get_ports -filter {DIRECTION == IN && NAME != clk}]
    set_output_delay 0 -clock probe_clk [get_ports -filter {DIRECTION == OUT}]
    report_utilization -hierarchical -file [file join $out ${profile}-synth-util.rpt]
    opt_design
    place_design
    route_design
    set query [get_ports -regexp {^c_addr\[[0-9]+\]$}]
    set data [get_ports -regexp {^c_rdata\[[0-9]+\]$}]
    if {[llength $query] != 32 || [llength $data] != 32} {error {port cardinality}}
    report_utilization -hierarchical -file [file join $out ${profile}-route-util.rpt]
    report_route_status -file [file join $out ${profile}-route-status.rpt]
    report_timing_summary -file [file join $out ${profile}-timing-summary.rpt]
    report_timing -from $query -to $data -max_paths 1 -file [file join $out ${profile}-query-data.rpt]
    report_timing -from $query -to [get_ports c_ack] -max_paths 1 -file [file join $out ${profile}-query-ack.rpt]
    report_timing -to $data -max_paths 1 -file [file join $out ${profile}-all-data.rpt]
    write_checkpoint [file join $out ${profile}-leaf.dcp]
    puts $receipt [list PROFILE $profile QUERY_PORTS [llength $query] DATA_PORTS [llength $data] CPU_FMAX_QUALIFIED 0]
    flush $receipt
    close_project
}
puts $receipt [list COMPLETE PROFILES 2 PRODUCTION_MUTATION 0 HARDWARE_ACCEPTANCE 0]
close $receipt
