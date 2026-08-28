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
report_utilization -file [file join [get_property DIRECTORY [get_runs impl_1]] post_impl_utilization.rpt]
report_timing_summary -file [file join [get_property DIRECTORY [get_runs impl_1]] post_impl_timing_summary.rpt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "## IMPL OK"
puts "## WNS (setup worst slack) = $wns"
close_project
