# Read-only follow-up for no_clock / unconstrained DSP startpoints. Invoke only
# through run_vivado_exclusive.sh after the synthesis and timing owners close.
# This collects evidence; it never waives a path or declares timing closure.
# Command contracts: AMD UG835 check_timing and report_exceptions.
if {$argc != 2} {error "usage: report_rk_timing_coverage.tcl project.xpr new-output-directory"}
set project [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {![file isfile $project] || [file exists $out]} {error "require an existing project and fresh output directory"}
set_param general.maxThreads 1
open_project $project
set synth [get_runs synth_1]
if {[get_property STATUS $synth] ne {synth_design Complete!} ||
    [get_property PROGRESS $synth] ne {100%} ||
    [string tolower [get_property NEEDS_REFRESH $synth]] ni {0 false}} {
    error "synthesis is missing, incomplete or stale"
}
if {[get_property STATUS [get_runs impl_1]] ne {Not started}} {
    error "this diagnostic requires the unimplemented synthesis project"
}
open_run synth_1
if {[get_property PART [current_design]] ne {xczu15eg-ffvb1156-2-i}} {error "wrong part"}
foreach {clock period} {clk_pl_0 10.0 mmcm_clk 25.0} {
    set clocks [get_clocks -quiet $clock]
    if {[llength $clocks] != 1 || abs([get_property PERIOD $clocks]-$period) > 0.001} {
        error "missing or wrong original clock $clock"
    }
}
file mkdir $out
check_timing -verbose -file [file join $out check_timing_verbose.rpt]
report_exceptions -summary -file [file join $out exceptions_summary.rpt]
report_exceptions -coverage -file [file join $out exceptions_coverage.rpt]
report_clocks -file [file join $out clocks.rpt]

# The parent's unconstrained paths start at ex_mul_p0__{1,2}/DSP_A_B_DATA_INST/
# B2_DATA[17] and terminate at EFLAGS. Do not assume this is either a live
# unclocked register or a disabled primitive timing arc. Record actual primitive
# configuration and pin connectivity, including clock nets, for that decision.
set f [open [file join $out integer_multiplier_dsp.rpt] {WRONLY CREAT EXCL}]
set cells [get_cells -hierarchical -quiet -filter {NAME =~ *ex_mul_p* && REF_NAME =~ DSP*}]
puts $f [list CELL_COUNT [llength $cells]]
foreach c [lsort $cells] {
    puts $f [list CELL $c]
    foreach p [lsort [list_property $c]] {
        puts $f [list PROPERTY $p [get_property $p $c]]
    }
    foreach p [lsort [get_pins -of_objects $c]] {
        set nets [get_nets -quiet -of_objects $p]
        puts $f [list PIN $p DIRECTION [get_property DIRECTION $p] NETS $nets]
        foreach n $nets {
            puts $f [list CONNECTED $n PINS [lsort [get_pins -quiet -of_objects $n]]]
        }
    }
}
close $f
if {![llength $cells]} {error "integer multiplier DSP mapping not found; investigate hierarchy, do not accept an empty report"}
set f [open [file join $out constraint_files.rpt] {WRONLY CREAT EXCL}]
foreach c [lsort [get_files -of_objects [get_filesets constrs_1]]] {
    puts $f [list FILE $c USED_IN_SYNTHESIS [get_property USED_IN_SYNTHESIS $c] \
        USED_IN_IMPLEMENTATION [get_property USED_IN_IMPLEMENTATION $c]]
}
close $f
close_project
puts {RK_TIMING_COVERAGE_COLLECTED timing_closed=false hardware_accepted=false}
