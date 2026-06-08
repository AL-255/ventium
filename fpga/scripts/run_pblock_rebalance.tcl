# =====================================================================
# u_icache REBALANCE experiment (user request): the default place concentrates the
# u_icache/byte-window cells in the upper-LEFT band (cols 0-2 = 95-100%) where the
# level-5 MUXF congestion is, while the upper-RIGHT (cols 4-5 = 27-67%) holds other
# modules. This forces u_icache into a Pblock spanning the UPPER region FULL WIDTH,
# sized so the placer must spread it EVENLY across the width (not pile on the left),
# pushing the other modules to the lower region. Then route + report congestion to see
# if even spread relieves the MUXF density. Fresh place from the synth checkpoint so the
# placer can move the OTHER modules too (an incremental re-place of only u_icache cannot,
# since the rest stays pinned). Plain phys_opt (AggressiveExplore thrashed the route).
#
# Env: CLOCK_NS (22), PB_YLO (lower Y of the u_icache Pblock; default 118), PLACE_DIR,
#      ROUTE_DIR.
# Run:  CLOCK_NS=22 vivado -mode batch -source fpga/scripts/run_pblock_rebalance.tcl -notrace
# =====================================================================
proc env_or {name def} { if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) } else { return $def } }
set ROOT [pwd]
if {![file exists $ROOT/fpga/build/strat/core_synth.dcp]} { set ROOT [file normalize [file join [file dirname [info script]] .. ..]] }
set DCP $ROOT/fpga/build/strat/core_synth.dcp
set OUT $ROOT/fpga/build/pblock_rebal
file mkdir $OUT
set CLOCK_NS [env_or CLOCK_NS 22]
set PB_YLO   [env_or PB_YLO 118]
set PLACE_DIR [env_or PLACE_DIR AltSpreadLogic_high]
set ROUTE_DIR [env_or ROUTE_DIR AlternateCLBRouting]

puts "PBLOCK_REBAL: clock=${CLOCK_NS}ns u_icache Pblock = upper region (SLICE Y${PB_YLO}+, full width)"
open_checkpoint $DCP
set cx $OUT/clk.xdc
set fh [open $cx w]; puts $fh "create_clock -period $CLOCK_NS -name clk \[get_ports clk\]"; close $fh
read_xdc $cx

# discover the SLICE grid extent so the Pblock spans the true full width + top.
set sl [get_sites -filter {SITE_TYPE =~ SLICE*}]
set xmax 0; set ymax 0
foreach s $sl { if {[regexp {SLICE_X([0-9]+)Y([0-9]+)} $s -> sx sy]} { if {$sx>$xmax} {set xmax $sx}; if {$sy>$ymax} {set ymax $sy} } }
puts "PBLOCK_REBAL: SLICE grid X0..$xmax Y0..$ymax"

create_pblock pb_ic
add_cells_to_pblock pb_ic [get_cells u_icache]
resize_pblock pb_ic -add "SLICE_X0Y${PB_YLO}:SLICE_X${xmax}Y${ymax}"
# do NOT set EXCLUDE_PLACEMENT — other modules may use the upper gaps; u_icache is
# CONSTRAINED to the upper region (cannot dip down), so it must spread across the width.
report_property [get_pblocks pb_ic] -file $OUT/pblock.rpt

opt_design
place_design -directive $PLACE_DIR
phys_opt_design
report_utilization -file $OUT/util.rpt
report_timing_summary -max_paths 4 -delay_type max -file $OUT/timing_placed.rpt
report_design_analysis -congestion -file $OUT/congestion_placed.rpt
write_checkpoint -force $OUT/core_rebal_placed.dcp
puts "PBLOCK_REBAL_PLACED_DONE"

# device-view CSV after place (guaranteed)
set fh [open $OUT/cells_loc.csv w]; puts $fh "module,x,y"; set n 0
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE==1}] {
    set loc [get_property LOC $c]; if {$loc eq ""} continue
    if {![regexp {[A-Z_]+X([0-9]+)Y([0-9]+)} $loc -> x y]} continue
    set nm [get_property NAME $c]
    if {[regexp {^(u_[A-Za-z0-9_]+)/} $nm -> inst]} { set mod $inst } else { set mod "core_spine" }
    puts $fh "$mod,$x,$y"; incr n
}
close $fh
puts "PBLOCK_REBAL_CSV_DONE cells=$n"

route_design -directive $ROUTE_DIR
phys_opt_design
report_timing_summary -max_paths 6 -delay_type max -file $OUT/timing_routed.rpt
report_design_analysis -congestion -file $OUT/congestion_routed.rpt
puts "PBLOCK_REBAL_ROUTED_DONE"
puts "STRAT_DONE pblock_rebal"
