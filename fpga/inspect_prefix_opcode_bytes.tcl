# Reopen the closed leaf DCPs; distinguish byte-data paths from valid-count paths.
# No synthesis, placement, routing, bitstream or constraint changes.
if {$argc != 2} {error {usage: inspect_prefix_opcode_bytes.tcl closed_reports fresh_output}}
set reports [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error {fresh report destination required}}
file mkdir $out
set_param general.maxThreads 1
set receipt [open [file join $out receipt.tsv] {WRONLY CREAT EXCL}]
puts $receipt "variant\tbyte_launch_registers\tfetch_slack_ns\tdata_ns\tlogic_levels"
foreach variant {parent fixed} {
    open_checkpoint [file join $reports ${variant}.dcp]
    # The bracket distinguishes r_ibuf_reg[byte][bit] from r_ibuf_valid_reg[bit].
    set starts [get_cells -hier -regexp {.*r_ibuf_reg\[.*}]
    if {[llength $starts] < 128} {error {missing byte launch registers}}
    set ends [get_pins -of_objects [get_cells -hier -filter {NAME =~ *d_fetch_need_reg*}] -filter {REF_PIN_NAME == D}]
    if {[llength $ends] == 0} {error {missing fetch-demand capture registers}}
    report_timing -from $starts -to $ends -max_paths 5 -file [file join $out ${variant}-byte-fetch.rpt]
    set path [get_timing_paths -from $starts -to $ends -max_paths 1]
    if {[llength $path] != 1} {error {missing byte-to-demand path}}
    puts $receipt "$variant\t[llength $starts]\t[get_property SLACK $path]\t[get_property DATAPATH_DELAY $path]\t[get_property LOGIC_LEVELS $path]"
    flush $receipt
    close_design
}
puts $receipt {COMPLETE CORE_FMAX_QUALIFIED=0 ROUTED=0}
close $receipt
