# Read-only inspection of the failed route's actual LUT equations. This does
# not declare paths false, alter constraints, optimize, route, or write a DCP.
if {$argc != 3} {error {usage: report_prefix_fanin.tcl checkpoint sha256 fresh-report-dir}}
if {[version -short] ne {2025.2}} {error {wrong Vivado version}}
set dcp [file normalize [lindex $argv 0]]
set digest [lindex $argv 1]
set out [file normalize [lindex $argv 2]]
if {![regexp {^[0-9a-f]{64}$} $digest] ||
    [lindex [exec sha256sum -- $dcp] 0] ne $digest} {error {DCP pin differs}}
if {[file exists $out] || [string first "[file normalize /home/yukidama/external/tmp]/" $out] != 0} {
    error {fresh external report directory required}
}
set_param general.maxThreads 1
open_checkpoint $dcp
try {
    if {[get_property PART [current_project]] ne {xczu15eg-ffvb1156-2-i} ||
        [get_property TOP [current_design]] ne {rk_ao486_bd_wrapper}} {error {wrong part/top}}
    file mkdir $out
    set report [open [file join $out logic_fanin.rpt] {WRONLY CREAT EXCL}]
    puts $report {Failed-route LUT connectivity. Rebuilt hierarchy/name sharing is not RTL ownership.}
    set count 0
    foreach cell [get_cells -hier -filter {IS_PRIMITIVE == 1 && REF_NAME =~ LUT*}] {
        if {![regexp {/(p54_prefix_ex_retire_pc_valid_q_i_(56|27|8|3|1)|p54_prior_write_mask\[7\]_i_(28|15|8|2)|p54_prior_write_mask\[2\]_i_7|mispred_bubbles\[2\]_i_6)$} $cell]} {
            continue
        }
        incr count
        puts $report [list CELL $cell REF [get_property REF_NAME $cell] INIT [get_property INIT $cell]]
        foreach pin [lsort [get_pins -of_objects $cell]] {
            set direction [get_property DIRECTION $pin]
            set nets [get_nets -of_objects $pin]
            puts $report [list PIN $pin DIRECTION $direction NETS $nets]
            if {$direction eq {IN}} {
                foreach driver [get_pins -leaf -of_objects $nets -filter {DIRECTION == OUT}] {
                    set owner [get_cells -of_objects $driver]
                    puts $report [list DRIVER $driver REF [get_property REF_NAME $owner]]
                }
            }
        }
    }
    puts $report [list SELECTED_CELL_COUNT $count]
    close $report
    if {$count < 11} {error "missing critical-cone cells: $count"}
    set clock [get_clocks -quiet mmcm_clk]
    if {[llength $clock]!=1 || abs([get_property PERIOD $clock]-25.0)>0.001} {error {wrong core clock}}
    report_timing -from $clock -to $clock -setup -max_paths 1 -path_type full_clock_expanded \
        -file [file join $out critical_path.rpt]
} finally {
    close_project
}
if {[lindex [exec sha256sum -- $dcp] 0] ne $digest} {error {DCP changed}}
puts {## READ_ONLY_PREFIX_FANIN_COMPLETE (not routing/timing/CPU acceptance)}
