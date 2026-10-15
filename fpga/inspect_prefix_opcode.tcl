# Matched isolated decoder mapping, not processor Fmax or routed acceptance.
if {$argc != 2} {error {usage: inspect_prefix_opcode.tcl inputs reports}}
if {[version -short] ne {2025.2}} {error {unexpected Vivado version}}
set inputs [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error {fresh reports directory required}}
file mkdir $out
set_param general.maxThreads 1
source [file join $inputs definitions.tcl]
set receipt [open [file join $out receipt.tsv] {WRONLY CREAT EXCL}]
puts $receipt "variant\tluts\tregisters\tworst_slack_ns\tfetch_slack_ns\tfetch_levels\tfetch_data_ns"
foreach variant {parent fixed} {
    create_project -in_memory -part xczu15eg-ffvb1156-2-i prefix_opcode
    set_property verilog_define $definitions [current_fileset]
    set files {}
    foreach name {ventium_pkg ventium_alu_pkg ventium_decode_pkg fpu_x87_pkg ventium_x87_pkg ventium_sys_pkg sysop_type} {
        lappend files [file join $inputs ${name}.sv]
    }
    lappend files [file join $inputs ${variant}.sv] [file join $inputs wrapper.sv]
    read_verilog -sv $files
    synth_design -top decode_probe -mode out_of_context -flatten_hierarchy rebuilt -directive Default -no_timing_driven
    create_clock -name core_clk -period 25 [get_ports clk]
    report_utilization -file [file join $out ${variant}-util.rpt]
    report_timing_summary -file [file join $out ${variant}-summary.rpt]
    report_timing -max_paths 10 -file [file join $out ${variant}-paths.rpt]
    set ends [get_pins -of_objects [get_cells -hier -filter {NAME =~ *d_fetch_need_reg*}] -filter {REF_PIN_NAME == D}]
    if {[llength $ends] == 0} {error {missing registered fetch-demand endpoints}}
    report_timing -to $ends -max_paths 5 -file [file join $out ${variant}-fetch.rpt]
    set fetch [get_timing_paths -to $ends -max_paths 1]
    set worst [get_timing_paths -max_paths 1]
    if {[llength $fetch] != 1 || [llength $worst] != 1} {error {missing timing path}}
    set luts [llength [get_cells -hier -filter {IS_PRIMITIVE == 1 && REF_NAME =~ LUT*}]]
    set regs [llength [get_cells -hier -filter {IS_PRIMITIVE == 1 && REF_NAME =~ FD*}]]
    puts $receipt "$variant\t$luts\t$regs\t[get_property SLACK $worst]\t[get_property SLACK $fetch]\t[get_property LOGIC_LEVELS $fetch]\t[get_property DATAPATH_DELAY $fetch]"
    flush $receipt
    write_checkpoint [file join $out ${variant}.dcp]
    close_project
}
puts $receipt {COMPLETE CORE_FMAX_QUALIFIED=0 ROUTED=0 STANDARD_SUITE=0}
close $receipt
puts {PREFIX-OPCODE-PROBE-OK}
