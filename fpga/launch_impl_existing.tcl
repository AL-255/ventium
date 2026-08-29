# Resume implementation from an already-completed Vivado synthesis run.
#
# The normal project generator launches synth+impl together.  Keeping this small
# entry point lets a long synthesis checkpoint be inspected before committing to
# placement and routing, without recreating the block design or rerunning synth.
if {$argc != 1} {
    error "usage: vivado -mode batch -source launch_impl_existing.tcl -tclargs <project.xpr>"
}

set project [file normalize [lindex $argv 0]]
open_project $project
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "synth_1 is not complete"
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "impl_1 failed (PROGRESS=[get_property PROGRESS [get_runs impl_1]])"
}

open_run impl_1
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
report_utilization -file [file join $impl_dir post_impl_utilization.rpt]
report_timing_summary -file [file join $impl_dir post_impl_timing_summary.rpt]

# Report the constrained clocks before slack.  Slack proves closure only at the
# constraint; it is not a frequency measurement.  These names are emitted by
# the /32 clock-divider constraints in the RK board build.
proc report_clock_frequency {clock_name role} {
    set clock [get_clocks -quiet $clock_name]
    if {[llength $clock] != 1} {
        error "expected exactly one $role clock named '$clock_name', found [llength $clock]"
    }
    set period_ns [get_property PERIOD $clock]
    if {![string is double -strict $period_ns] || $period_ns <= 0.0} {
        error "clock '$clock_name' has invalid PERIOD '$period_ns'"
    }
    puts [format "## Frequency (%s): %.6f MHz (%.6f ns constrained period)" \
        $role [expr {1000.0 / $period_ns}] $period_ns]
}

puts "## IMPL OK"
report_clock_frequency clk_pl_0 "PL / HP0"
report_clock_frequency wr_clk_i "core (/32)"

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "## WNS (setup worst slack) = $wns"
puts "## WHS (hold worst slack) = $whs"
close_project
