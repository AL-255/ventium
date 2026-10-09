# Exact-profile isolated A/B. Local zero-delay port budgets are not CPU Fmax.
# Invoke only via run_vivado_exclusive.sh and a bounded resource supervisor.
if {$argc != 4} {error {usage: control_source candidate_source defines_file fresh_output}}
if {[version -short] ne {2025.2}} {error {unexpected Vivado version}}
set control [file normalize [lindex $argv 0]]
set candidate [file normalize [lindex $argv 1]]
set definitions [file normalize [lindex $argv 2]]
set out [file normalize [lindex $argv 3]]
if {[file exists $out]} {error {fresh output required}}
set handle [open $definitions r]
set defs [split [string trim [read $handle]] "\n"]
close $handle
if {[llength $defs] != 119 || [llength [lsort -unique $defs]] != 119} {
    error {expected the complete 119-macro pop-drain SoC parent profile}
}
foreach def $defs {
    if {![regexp {^VEN_[A-Z0-9_]+$} $def]} {error "invalid macro $def"}
}
if {[lsearch -exact $defs VEN_L1D_CODE_WORD_REUSE] != -1} {error {parent already enables reuse}}
file mkdir $out
set receipt [open [file join $out receipt.tcllist] {WRONLY CREAT EXCL}]
set_param general.maxThreads 1
foreach profile {control candidate} {
    set source [set $profile]
    set macros [concat $defs {SYNTHESIS VTM_NO_DPI}]
    if {$profile eq {candidate}} {lappend macros VEN_L1D_CODE_WORD_REUSE}
    create_project -in_memory -part xczu15eg-ffvb1156-2-i code_word_probe
    set_property verilog_define $macros [current_fileset]
    read_verilog -sv [list $source/rtl/mem/ven_p54_bank_arb.sv \
        $source/rtl/mem/ven_p54_hit_return.sv $source/rtl/mem/ven_l1d.sv]
    synth_design -top ven_l1d -mode out_of_context -flatten_hierarchy rebuilt
    create_clock -name probe_clk -period 25 [get_ports clk]
    set_input_delay 0 -clock probe_clk [get_ports -filter {DIRECTION == IN && NAME != clk}]
    set_output_delay 0 -clock probe_clk [get_ports -filter {DIRECTION == OUT}]
    report_utilization -hierarchical -file [file join $out ${profile}-synth-util.rpt]
    opt_design
    place_design
    route_design
    report_utilization -hierarchical -file [file join $out ${profile}-route-util.rpt]
    report_route_status -file [file join $out ${profile}-route-status.rpt]
    report_timing_summary -file [file join $out ${profile}-timing-summary.rpt]
    set query [get_ports -regexp {^c_addr\[[0-9]+\]$}]
    set data [get_ports -regexp {^c_rdata\[[0-9]+\]$}]
    if {[llength $query] != 32 || [llength $data] != 32} {error {wrong port cardinality}}
    report_timing -from $query -to $data -max_paths 1 -file [file join $out ${profile}-query-data.rpt]
    report_timing -from $query -to [get_ports c_ack] -max_paths 1 -file [file join $out ${profile}-query-ack.rpt]
    set setup [get_timing_paths -delay_type max -max_paths 1]
    set hold [get_timing_paths -delay_type min -max_paths 1]
    if {[llength $setup] != 1 || [llength $hold] != 1} {error {missing timing path}}
    set wns [get_property SLACK $setup]
    set whs [get_property SLACK $hold]
    set estimate [expr {1000.0 / (25.0 - $wns)}]
    write_checkpoint [file join $out ${profile}-leaf.dcp]
    puts $receipt [list PROFILE $profile WNS_NS $wns WHS_NS $whs \
        LOCAL_ZERO_IO_SETUP_ESTIMATE_MHZ $estimate CPU_FMAX_QUALIFIED 0]
    flush $receipt
    close_project
}
puts $receipt {COMPLETE PROFILES 2 HARDWARE_ACCEPTANCE 0}
close $receipt
