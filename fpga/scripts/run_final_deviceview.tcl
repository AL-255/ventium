# =====================================================================
# FINAL run for the BEST config (narrowB): reopen the synth checkpoint, place + FULLY
# ROUTE at a meetable clock, write the routed checkpoint, report util + placed/routed
# timing + congestion, and dump every placed leaf cell's LOC + top module to a CSV for
# the colored device-view image. This is the "one final run till it finishes routing"
# + the device-view source. Plain phys_opt (NOT AggressiveExplore, which thrashed the
# congested route). Clock via CLOCK_NS env (default 22).
#
# Run:  CLOCK_NS=22 vivado -mode batch -source fpga/scripts/run_final_deviceview.tcl -notrace
# =====================================================================
proc env_or {name def} { if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) } else { return $def } }
set ROOT [pwd]
if {![file exists $ROOT/fpga/build/strat/core_synth.dcp]} { set ROOT [file normalize [file join [file dirname [info script]] .. ..]] }
set DCP $ROOT/fpga/build/strat/core_synth.dcp
set OUT $ROOT/fpga/build/final_dv
file mkdir $OUT
set CLOCK_NS [env_or CLOCK_NS 22]
set PLACE_DIR [env_or PLACE_DIR AltSpreadLogic_high]
set ROUTE_DIR [env_or ROUTE_DIR AlternateCLBRouting]

puts "FINAL_DV: clock=${CLOCK_NS}ns place=$PLACE_DIR route=$ROUTE_DIR"
open_checkpoint $DCP
set cx $OUT/clk.xdc
set fh [open $cx w]; puts $fh "create_clock -period $CLOCK_NS -name clk \[get_ports clk\]"; close $fh
read_xdc $cx

opt_design
place_design -directive $PLACE_DIR
phys_opt_design
report_utilization -file $OUT/util.rpt
report_timing_summary -max_paths 4 -delay_type max -file $OUT/timing_placed.rpt
report_design_analysis -congestion -file $OUT/congestion_placed.rpt
write_checkpoint -force $OUT/core_final_placed.dcp
puts "FINAL_DV_PLACED_DONE"

# ---- device-view CSV dumped AFTER PLACE (cell LOCs are fixed at place; routing
# does not move them) so the colored device view is GUARANTEED even if the route
# does not converge at this clock. ------------------------------------------
proc dump_cells {path} {
    set fh [open $path w]; puts $fh "module,x,y"; set n 0
    foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE==1}] {
        set loc [get_property LOC $c]
        if {$loc eq ""} continue
        if {![regexp {[A-Z_]+X([0-9]+)Y([0-9]+)} $loc -> x y]} continue
        set nm [get_property NAME $c]
        if {[regexp {^(u_[A-Za-z0-9_]+)/} $nm -> inst]} { set mod $inst } else { set mod "core_spine" }
        puts $fh "$mod,$x,$y"; incr n
    }
    close $fh; return $n
}
set ncells [dump_cells $OUT/cells_loc.csv]
puts "FINAL_DV_CSV_DONE cells=$ncells"

route_design -directive $ROUTE_DIR
phys_opt_design
report_timing_summary -max_paths 6 -delay_type max -file $OUT/timing_routed.rpt
report_design_analysis -congestion -file $OUT/congestion_routed.rpt
write_checkpoint -force $OUT/core_final_routed.dcp
puts "FINAL_DV_ROUTED_DONE"
puts "STRAT_DONE final_dv"
