# =====================================================================
# OOC place & route the consolidated core synth checkpoint to get the TRUE
# post-route Fmax (the synth-probe WNS is a pre-placement estimate). Opens the
# core_bcd_synth.dcp (all 3 iter defines, 91.7% LUT) and runs opt/place/route at
# a tight 15 ns target (66.7 MHz) so the WNS reads directly against the goal.
#
# Run:  vivado -mode batch -source fpga/scripts/impl_core_route.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/fpga/build/synthprobe_core_bcd/core_bcd_synth.dcp]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set DCP $ROOT/fpga/build/synthprobe_core_bcd/core_bcd_synth.dcp
set OUT $ROOT/fpga/build/impl_core_bcd
file mkdir $OUT

puts "IMPL(core): opening $DCP"
open_checkpoint $DCP

# Retarget the clock to 15 ns (66.7 MHz) so WNS is measured against the goal.
set xdc $OUT/core_clk15.xdc
set fh [open $xdc w]
puts $fh "create_clock -period 15.000 -name clk \[get_ports clk\]"
close $fh
read_xdc $xdc

puts "IMPL(core): opt_design ..."
opt_design
puts "IMPL(core): place_design ..."
place_design
puts "IMPL(core): phys_opt_design ..."
phys_opt_design

# POST-PLACE reports FIRST (the Fmax indicator) — routing a 91.7%-full device is
# slow/congested, so capture the placed-timing estimate before attempting route.
report_utilization                       -file $OUT/util_placed.rpt
report_timing_summary -max_paths 20 -delay_type max -file $OUT/timing_placed.rpt
report_timing -max_paths 12 -sort_by group -input_pins -file $OUT/timing_paths_placed.rpt
write_checkpoint -force $OUT/core_placed.dcp
puts "IMPL_CORE_PLACED_DONE"

# Best-effort full route (may be slow at 91.7%); the placed report above already
# gives the Fmax estimate, so this is a bonus ground-truth pass.
puts "IMPL(core): route_design ..."
route_design
report_timing_summary -max_paths 20 -delay_type max -file $OUT/timing_routed.rpt
report_timing -max_paths 12 -sort_by group -input_pins -file $OUT/timing_paths_routed.rpt
write_checkpoint -force $OUT/core_routed.dcp
puts "IMPL_CORE_ROUTED_DONE"
