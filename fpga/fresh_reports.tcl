# Final read-only evidence: clocks, all four clock-pair paths and legality.
set f [open [file join $out timing.tsv] {WRONLY CREAT EXCL}]
puts $f "from_clock\tto_clock\tsetup_ns\thold_ns\tperiod_ns\trequirement_ns\texception\tconditional_mhz"
set core {}; set axi {}
foreach c [get_clocks] {
    set period [get_property PERIOD $c]
    if {abs($period-25.0)<0.001} {lappend core $c}
    # Exclude the 100 MHz MMCM feedback clock from the functional AXI role.
    if {[get_property NAME $c] eq "clk_pl_0" && abs($period-10.0)<0.001} {lappend axi $c}
}
if {[llength $core] != 1 || [llength $axi] != 1} {error "missing/ambiguous final clocks"}
foreach {from to} [list $core $core $axi $axi $core $axi $axi $core] {
    set setup [get_timing_paths -setup -from $from -to $to -max_paths 1]
    set hold [get_timing_paths -hold -from $from -to $to -max_paths 1]
    if {[llength $setup] != 1 || [llength $hold] != 1} {error "missing clock pair timing"}
    set slack [get_property SLACK $setup]
    set hs [get_property SLACK $hold]
    set period [get_property PERIOD $to]
    set req [get_property REQUIREMENT $setup]
    set exc [get_property EXCEPTION $setup]
    set mhz NA
    if {$from eq $to && abs($period-$req)<0.001 && [string tolower [string trim $exc]] in {"" none} && $period-$slack>0} {
        set mhz [format %.9f [expr {1000.0/($period-$slack)}]]
    }
    # Canonical role names, not a dependency on generated net naming.
    set from_name [expr {$from eq $core ? "mmcm_clk" : "clk_pl_0"}]
    set to_name [expr {$to eq $core ? "mmcm_clk" : "clk_pl_0"}]
    puts $f "$from_name\t$to_name\t$slack\t$hs\t$period\t$req\t$exc\t$mhz"
}
close $f
report_clocks -file [file join $out clocks.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -max_paths 10 -file [file join $out timing-summary.rpt]
report_timing -from $core -to $core -max_paths 20 -path_type full_clock_expanded -file [file join $out core-paths.rpt]
report_utilization -hierarchical -file [file join $out utilization.rpt]
report_route_status -file [file join $out route-status.rpt]
report_drc -no_waivers -file [file join $out drc.rpt]
check_timing -verbose -file [file join $out check-timing.rpt]
report_exceptions -coverage -file [file join $out exceptions.rpt]
report_cdc -details -no_waiver -all_checks_per_endpoint -file [file join $out cdc.rpt]
report_bus_skew -delay_type min_max -file [file join $out bus-skew.rpt]
report_design_analysis -congestion -file [file join $out congestion.rpt]
set mmcm [get_cells -hier -filter {REF_NAME == MMCME4_ADV}]
if {[llength $mmcm] != 1} {error "expected one MMCM"}
foreach {prop expected} {CLKFBOUT_MULT_F 10 CLKOUT0_DIVIDE_F 25 DIVCLK_DIVIDE 1} {
    if {[get_property $prop $mmcm] != $expected} {error "MMCM changed: $prop"}
}
foreach {check expected} {PLACED_FULLY 1 ROUTED_FULLY 1 PARTIALLY_ROUTED 0 ERRORS_IN_ROUTES 0} {
    if {[report_route_status -boolean_check $check] != $expected} {error "route legality: $check"}
}
# A freshly produced result for evidence/deployment, NEVER input to another trial.
write_checkpoint [file join $out fresh-routed.dcp]
