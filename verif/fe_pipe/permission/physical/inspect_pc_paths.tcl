# Three isolated routed leaves. No production project/checkpoint/board changes.
if {$argc != 1} {error {usage: inspect_pc_paths.tcl fresh_output}}
if {[version -short] ne {2025.2}} {error {tool identity}}
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error {fresh output required}}
file mkdir $out
set root [file dirname [file normalize [info script]]]
set receipt [open [file join $out receipt.tcllist] {WRONLY CREAT EXCL}]
set_param general.maxThreads 1
proc pins_matching {pattern pin} {
    set cells [get_cells -quiet -hier -regexp $pattern]
    if {![llength $cells]} {error "no cells for $pattern"}
    return [get_pins -of_objects $cells -filter "REF_PIN_NAME == $pin"]
}
foreach profile {{direct 0 0} {address8 8 0} {permission8 8 1}} {
    lassign $profile cut entries permcut
    create_project -in_memory -part xczu15eg-ffvb1156-2-i cut_probe
    set_property verilog_define {VTM_NO_DPI VEN_P54_DUAL_HIT} [current_fileset]
    read_verilog -sv [list $root/tlb_assoc.sv $root/ven_fe_dtlb.sv $root/tlb_cut_probe.sv]
    synth_design -top tlb_cut_probe -mode out_of_context -flatten_hierarchy rebuilt -generic [list CUT=$entries PERM_CUT=$permcut]
    create_clock -name probe_clk -period 25 [get_ports clk]
    report_utilization -hierarchical -file [file join $out cut${cut}-synth-util.rpt]
    opt_design
    place_design
    route_design
    set phys_d [pins_matching {^phys_o_reg\[[0-9]+\]$} D]
    set query_q [pins_matching {^query_q_reg\[[0-9]+\]$} Q]
    set perm_d [pins_matching {^perm_o_reg\[[0-9]+\]$} D]
    set pair_d [pins_matching {^pair_phys_o_reg\[[0-9]+\]$} D]
    set pair_q [pins_matching {^pair_q_reg\[[0-9]+\]$} Q]
    set fault_d [pins_matching {^perm_fault_o_reg$} D]
    if {[llength $fault_d] != 1} {error {permission fault cardinality}}
    if {[llength $phys_d] != 32 || [llength $query_q] != 32 || [llength $perm_d] != 3 || [llength $pair_d] != 32 || [llength $pair_q] != 32} {error {boundary cardinality}}
    report_utilization -hierarchical -file [file join $out cut${cut}-route-util.rpt]
    report_route_status -file [file join $out cut${cut}-route-status.rpt]
    report_timing_summary -file [file join $out cut${cut}-timing-summary.rpt]
    report_timing -to $phys_d -max_paths 1 -file [file join $out cut${cut}-phys-all.rpt]
    report_timing -from $query_q -to $phys_d -max_paths 1 -file [file join $out cut${cut}-phys-query.rpt]
    report_timing -from $query_q -to $perm_d -max_paths 1 -file [file join $out cut${cut}-perm-query.rpt]
    report_timing -from $pair_q -to $pair_d -max_paths 1 -file [file join $out cut${cut}-pair-query.rpt]
    report_timing -from $query_q -to $fault_d -max_paths 1 -file [file join $out cut${cut}-fault-query.rpt]
    report_timing -to $fault_d -max_paths 1 -file [file join $out cut${cut}-fault-all.rpt]
    write_checkpoint [file join $out cut${cut}-leaf.dcp]
    puts $receipt [list CUT $cut BOUNDARY_PHYS [llength $phys_d] PRIMITIVES [llength [get_cells -hier -filter {IS_PRIMITIVE == 1}]] CPU_FMAX_QUALIFIED 0]
    flush $receipt
    close_project
}
puts $receipt [list COMPLETE PROFILES 3 PRODUCTION_MUTATION 0 HARDWARE_ACCEPTANCE 0]
close $receipt
