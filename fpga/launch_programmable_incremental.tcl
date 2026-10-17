# Same 40 MHz programmable-clock netlist. Reuse physical data, not old RTL.
if {$argc != 3} {error "usage: current-opt.dcp parent-routed.dcp output-dir"}
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
set_param general.maxThreads 1
set out [file normalize [lindex $argv 2]]
if {![file isdirectory $out]} {error "output directory must already exist"}

proc check_clocks {} {
    foreach {name period} {clk_pl_0 10.0 mmcm_clk 25.0} {
        set clk [get_clocks -quiet $name]
        if {[llength $clk] != 1 || abs([get_property PERIOD $clk]-$period) > 0.001} {
            error "incorrect constrained clock $name"
        }
        puts "CLOCK-ADMISSION $name [expr {1000.0/$period}] MHz"
    }
    set mmcm [get_cells -hier -filter {REF_NAME == MMCME4_ADV}]
    if {[llength $mmcm] != 1} {error "programmable MMCM missing or duplicated"}
    foreach {name expected} {CLKFBOUT_MULT_F 10 CLKOUT0_DIVIDE_F 25 DIVCLK_DIVIDE 1} {
        if {[get_property $name $mmcm] != $expected} {error "MMCM $name changed"}
    }
}

proc reuse_counts {stage} {
    set all [get_cells -hier -filter {IS_PRIMITIVE == 1}]
    set matched [get_cells -hier -filter {IS_PRIMITIVE == 1 && IS_MATCHED == 1}]
    set reused [get_cells -hier -filter {IS_PRIMITIVE == 1 && IS_REUSED == 1}]
    set total [llength $all]
    if {$total < 200000} {error "unexpectedly small current design"}
    set match_pct [expr {100.0*[llength $matched]/$total}]
    set reuse_pct [expr {100.0*[llength $reused]/$total}]
    set f [open [file join $::out ${stage}-reuse.json] {WRONLY CREAT EXCL}]
    puts $f [format {{"stage":"%s","primitive_cells":%d,"matched_pct":%.9f,"reused_pct":%.9f}} \
        $stage $total $match_pct $reuse_pct]
    close $f
    puts "REUSE-ADMISSION $stage cells=$total matched=$match_pct reused=$reuse_pct"
    # Do not silently fall back to another large full-placement experiment.
    if {$match_pct < 95.0 || $reuse_pct < 90.0} {error "insufficient physical reuse"}
}

# This checkpoint already contains r3's approved RuntimeOptimized opt_design
# and all implementation XDCs. Do not rerun synthesis or import the parent's
# logical design with open_checkpoint. The parent supplies matching locations
# and routes only, through the documented incremental command.
open_checkpoint [lindex $argv 0]
if {[get_property PART [current_design]] ne "xczu15eg-ffvb1156-2-i"} {error "wrong device"}
check_clocks
# Native r1 rejected this physically proven reference solely on WNS (-9.841 ns)
# and switched to full placement. Force the incremental algorithm, not timing
# acceptance; the independent match/reuse, route, DRC and runtime gates remain.
read_checkpoint -incremental -force_incr -directive RuntimeOptimized [lindex $argv 1]
check_clocks
report_incremental_reuse -file [file join $out initial-reuse.rpt]
reuse_counts initial
write_checkpoint [file join $out reuse-input.dcp]

# Incremental RuntimeOptimized preserves the reference's setup target; it is
# NOT a claim to have closed timing. Avoid globally replacing the known layout
# with AltSpreadLogic_high again, or asking TimingClosure to rip it all up.
place_design
check_clocks
report_incremental_reuse -file [file join $out placed-reuse.rpt]
report_utilization -file [file join $out placed-utilization.rpt]
reuse_counts placed
write_checkpoint [file join $out placed.dcp]
set route_start [clock milliseconds]
puts "PROGRAMMABLE-INCREMENTAL-ROUTE-START $route_start"
route_design
set route_ms [expr {[clock milliseconds]-$route_start}]
if {$route_ms < 0 || $route_ms >= 14400000} {error "routing exceeded the user's four-hour limit"}
puts "PROGRAMMABLE-INCREMENTAL-ROUTE-END milliseconds=$route_ms"
set f [open [file join $out route-time.json] {WRONLY CREAT EXCL}]
puts $f [format {{"route_elapsed_ms":%d,"limit_ms":14400000}} $route_ms]
close $f
write_checkpoint [file join $out routed.dcp]
check_clocks
report_route_status -file [file join $out route-status.rpt]
report_drc -file [file join $out drc.rpt]
report_clocks -file [file join $out clocks.rpt]
report_timing_summary -max_paths 10 -report_unconstrained -file [file join $out timing-summary.rpt]
report_incremental_reuse -file [file join $out routed-reuse.rpt]
report_utilization -file [file join $out utilization.rpt]
report_property [get_cells -hier -filter {REF_NAME == MMCME4_ADV}] -file [file join $out mmcm.rpt]

set core_path [get_timing_paths -setup -max_paths 1 -from [get_clocks mmcm_clk] -to [get_clocks mmcm_clk]]
if {[llength $core_path] != 1} {error "missing core setup path"}
set core_slack [get_property SLACK $core_path]
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -hold -max_paths 1]]
foreach value [list $core_slack $wns $whs] {
    if {![string is double -strict $value] || !($value > -Inf && $value < Inf)} {error "invalid slack"}
}
if {25.0-$core_slack <= 0} {error "invalid core timing budget"}
set estimate [expr {1000.0/(25.0-$core_slack)}]
set f [open [file join $out timing.json] {WRONLY CREAT EXCL}]
puts $f [format {{"core_constraint_mhz":40,"axi_constraint_mhz":100,"core_setup_slack_ns":%.6f,"conditional_core_period_budget_mhz":%.6f,"global_wns_ns":%.6f,"global_whs_ns":%.6f,"timing_signoff":false}} \
    $core_slack $estimate $wns $whs]
close $f
puts "TIMING core_constraint=40MHz AXI_constraint=100MHz conditional_core_budget=${estimate}MHz global_WNS=$wns WHS=$whs"
write_bitstream -bin_file [file join $out ventium_programmable_clock_40.bit]
puts "PROGRAMMABLE-INCREMENTAL-COMPLETE (not CPU or hardware acceptance)"
