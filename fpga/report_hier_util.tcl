# Usage: vivado -mode batch -source fpga/report_hier_util.tcl \
#        -tclargs <checkpoint.dcp> <report.rpt> ?depth?
set checkpoint [file normalize [lindex $argv 0]]
set report     [file normalize [lindex $argv 1]]
set depth      [expr {$argc >= 3 ? [lindex $argv 2] : 6}]
open_checkpoint $checkpoint
report_utilization -hierarchical -hierarchical_depth $depth -file $report
close_design
