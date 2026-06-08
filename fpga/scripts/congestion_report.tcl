# =====================================================================
# Congestion analysis on the placed best-config checkpoint — find WHERE the
# routing congestion is (which device regions, which level) so the floorplan can
# target it, instead of a blind soft-Pblock. Fast: opens core_best_placed.dcp,
# reports congestion + the per-module placement spread.
#
# Run:  vivado -mode batch -source fpga/scripts/congestion_report.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/fpga/build/device_view/core_best_placed.dcp]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set DCP $ROOT/fpga/build/device_view/core_best_placed.dcp
set OUT $ROOT/fpga/build/congestion
file mkdir $OUT
open_checkpoint $DCP

# Placement-level congestion (the placer's estimate of routing demand vs supply).
report_design_analysis -congestion -file $OUT/congestion.rpt
# Timing+congestion combined view of the worst paths.
report_design_analysis -timing -setup -max_paths 8 -file $OUT/timing_analysis.rpt
# Per-clock-region utilization (where the dense regions are).
report_utilization -slr -file $OUT/util_slr.rpt -quiet
# The placed bounding box of each major module (how spread each one is) — informs
# whether a per-module Pblock would help.
set fh [open $OUT/module_bbox.txt w]
foreach m {u_fpu_state u_icache u_bpred_btb u_dcache_tm u_idiv u_sqrt_iter u_srt_div u_bcd u_bcd2fp} {
    set cells [get_cells -hierarchical -filter "NAME =~ $m/* && IS_PRIMITIVE==1" -quiet]
    if {[llength $cells]==0} continue
    set xs {}; set ys {}
    foreach c $cells {
        set loc [get_property LOC $c]
        if {[regexp {[A-Z_]+X([0-9]+)Y([0-9]+)} $loc -> x y]} { lappend xs $x; lappend ys $y }
    }
    if {[llength $xs]==0} continue
    set xs [lsort -integer $xs]; set ys [lsort -integer $ys]
    puts $fh "$m: cells=[llength $cells]  X=[lindex $xs 0]..[lindex $xs end]  Y=[lindex $ys 0]..[lindex $ys end]"
}
close $fh
puts "CONGESTION_REPORT_DONE"
