# Independent implementation experiments from a pinned deployed routed netlist.
# No RTL, synthesis, clock relaxation, bitstream generation or board writes.
if {$argc != 4} {error "usage: checkpoint expected-sha256 strategy new-output-dir"}
if {[version -short] ne "2025.2"} {error "Vivado 2025.2 required"}
lassign $argv checkpoint expected strategy out
if {$strategy ni {postroute-aggressive postroute-replication replace-netdelay}} {error "unknown strategy"}
if {[lindex [exec sha256sum -- $checkpoint] 0] ne $expected} {error "input checkpoint hash mismatch"}
if {[file exists $out]} {error "output must be new"}
file mkdir $out
set_param general.maxThreads 1

proc clocks_ok {} {
    foreach {name period} {clk_pl_0 10.0 mmcm_clk 25.0} {
        set clk [get_clocks -quiet $name]
        if {[llength $clk] != 1 || abs([get_property PERIOD $clk]-$period) > 0.001} {
            error "incorrect constrained clock $name"
        }
    }
    set mmcm [get_cells -hier -filter {REF_NAME == MMCME4_ADV}]
    if {[llength $mmcm] != 1} {error "expected exactly one MMCM"}
    foreach {name expected} {CLKFBOUT_MULT_F 10 CLKOUT0_DIVIDE_F 25 DIVCLK_DIVIDE 1} {
        if {[get_property $name $mmcm] != $expected} {error "MMCM $name changed"}
    }
}
proc fully_routed {} {
    foreach {check expected} {PLACED_FULLY 1 ROUTED_FULLY 1 PARTIALLY_ROUTED 0 ERRORS_IN_ROUTES 0} {
        if {[report_route_status -boolean_check $check] != $expected} {error "route gate failed: $check"}
    }
}
proc measure {stage} {
    clocks_ok
    set f [open [file join $::out ${stage}-timing.tsv] {WRONLY CREAT EXCL}]
    puts $f "from_clock\tto_clock\tsetup_ns\thold_ns\tperiod_ns\trequirement_ns\texception\tconditional_mhz"
    foreach {from to} {mmcm_clk mmcm_clk clk_pl_0 clk_pl_0 mmcm_clk clk_pl_0 clk_pl_0 mmcm_clk} {
        set setup [get_timing_paths -setup -from [get_clocks $from] -to [get_clocks $to] -max_paths 1]
        set hold [get_timing_paths -hold -from [get_clocks $from] -to [get_clocks $to] -max_paths 1]
        if {[llength $setup] != 1 || [llength $hold] != 1} {error "missing $from -> $to timing path"}
        set slack [get_property SLACK $setup]
        set hs [get_property SLACK $hold]
        set period [get_property PERIOD [get_clocks $to]]
        set requirement [get_property REQUIREMENT $setup]
        set exception [get_property EXCEPTION $setup]
        set mhz "NA"
        if {$from eq $to && abs($requirement-$period)<0.001 &&
            [string tolower [string trim $exception]] in {"" none} && $period-$slack > 0} {
            set mhz [format %.9f [expr {1000.0/($period-$slack)}]]
        }
        puts $f "$from\t$to\t$slack\t$hs\t$period\t$requirement\t$exception\t$mhz"
        puts "APR-TIMING $stage $from->$to setup=$slack hold=$hs conditional_MHz=$mhz"
    }
    close $f
    report_timing_summary -delay_type min_max -report_unconstrained -max_paths 3 \
        -file [file join $::out ${stage}-timing-summary.rpt]
    report_timing -from [get_clocks mmcm_clk] -to [get_clocks mmcm_clk] -max_paths 10 \
        -path_type full_clock_expanded -file [file join $::out ${stage}-core-paths.rpt]
    report_route_status -file [file join $::out ${stage}-route-status.rpt]
    report_utilization -file [file join $::out ${stage}-utilization.rpt]
}
open_checkpoint $checkpoint
if {[get_property PART [current_design]] ne "xczu15eg-ffvb1156-2-i" ||
    [get_property TOP [current_design]] ne "rk_ao486_bd_wrapper"} {error "wrong part or top"}
clocks_ok
fully_routed
measure before
set f [open [file join $out stages.tsv] {WRONLY CREAT EXCL}]
puts $f "stage\tstart_ms\tend_ms"
proc timed {name command} {
    puts "APR-STAGE-BEGIN $name [clock milliseconds]"
    set start [clock milliseconds]
    uplevel #0 $command
    puts $::f "$name\t$start\t[clock milliseconds]"
    flush $::f
    puts "APR-STAGE-END $name [clock milliseconds]"
}
switch $strategy {
    postroute-aggressive {timed physopt {phys_opt_design -directive AggressiveExplore}}
    postroute-replication {timed physopt {phys_opt_design -directive AlternateReplication}}
    replace-netdelay {
        # Explicit full-placement experiment, NOT an incremental reuse claim.
        # Keep fixed hard-IP/IO constraints; no manual logic/reset/clock changes.
        timed unroute {route_design -unroute}
        timed unplace {place_design -unplace}
        timed place {place_design -directive ExtraNetDelay_high}
        write_checkpoint [file join $out placed.dcp]
        timed physopt {phys_opt_design -directive AggressiveExplore}
        write_checkpoint [file join $out physopt.dcp]
        timed route {route_design -directive NoTimingRelaxation}
    }
}
close $f
clocks_ok
# Retain native result even if a subsequent report/legality gate fails.
write_checkpoint [file join $out result.dcp]
fully_routed
measure after
report_clocks -file [file join $out clocks.rpt]
report_drc -no_waivers -file [file join $out drc.rpt]
report_exceptions -coverage -file [file join $out exceptions-coverage.rpt]
check_timing -verbose -file [file join $out check-timing.rpt]
report_cdc -details -no_waiver -all_checks_per_endpoint -file [file join $out cdc.rpt]
report_bus_skew -delay_type min_max -file [file join $out bus-skew.rpt]
report_design_analysis -congestion -file [file join $out congestion.rpt]
report_property [get_cells -hier -filter {REF_NAME == MMCME4_ADV}] -file [file join $out mmcm.rpt]
if {[lindex [exec sha256sum -- $checkpoint] 0] ne $expected} {error "input checkpoint changed"}
close_project
puts "APR-TRIAL-COMPLETE strategy=$strategy (not hardware or timing signoff)"
