# =====================================================================
# Full-SoC P&R strategy sweep — open the synthesized BD wrapper checkpoint and run
# ONE place/route strategy, reporting the routed WNS. The full SoC is 79% LUT and
# route-bound (the eip/TLB fetch front-end smears under the L1/AXI+BD die-fill), so
# this sweeps CONGESTION-relief vs TIMING placement to find the best in-context number
# without re-synthesizing.  (No RTL change — pure P&R.)
#
# Env: STRAT, PLACE_DIR, PHYSOPT_DIR, ROUTE_DIR, POSTROUTE_DIR, THREADS
# Run: STRAT=fs_spread PLACE_DIR=AltSpreadLogic_high ROUTE_DIR=AlternateCLBRouting \
#        /tools/Xilinx/2025.2/Vivado/bin/vivado -mode batch -source fpga/scripts/fs_pnr.tcl
# =====================================================================
proc env_or {n d} { if {[info exists ::env($n)] && $::env($n) ne ""} { return $::env($n) } else { return $d } }
set STRAT     [env_or STRAT     fs]
set PLACE     [env_or PLACE_DIR Explore]
set PHYS      [env_or PHYSOPT_DIR AggressiveExplore]
set ROUTE     [env_or ROUTE_DIR Explore]
set POSTROUTE [env_or POSTROUTE_DIR AggressiveExplore]
set THREADS   [env_or THREADS 8]
set_param general.maxThreads $THREADS

set ROOT [file normalize [file dirname [info script]]/../..]
# Open the FULLY-LINKED post-opt checkpoint from the baseline impl run (the synth
# wrapper.dcp is a project stub whose IP sub-checkpoints aren't linked -> opt DRC
# fails). _opt.dcp is post-opt_design, DRC-clean, so we place/route directly.
set DCP  $ROOT/fpga/build/kv260_soc_impl/proj/ventium_kv260_impl.runs/impl_1/design_kv260_wrapper_opt.dcp
set OUT  $ROOT/fpga/build/kv260_soc_impl/sweep/$STRAT
file mkdir $OUT
puts "FS_PNR $STRAT : place='$PLACE' physopt='$PHYS' route='$ROUTE' postroute='$POSTROUTE'"
open_checkpoint $DCP
place_design -directive $PLACE
if {$PHYS ne ""} { phys_opt_design -directive $PHYS }
report_design_analysis -congestion -file $OUT/congestion_placed.rpt
report_timing_summary -max_paths 4 -delay_type max -file $OUT/timing_placed.rpt
puts "FS_PNR_PLACED_DONE $STRAT"
route_design -directive $ROUTE
if {$POSTROUTE ne ""} { phys_opt_design -directive $POSTROUTE }
report_timing_summary -max_paths 10 -delay_type max -file $OUT/timing_routed.rpt
report_design_analysis -congestion -file $OUT/congestion_routed.rpt
write_checkpoint -force $OUT/routed.dcp
set wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
puts "FS_PNR_DONE $STRAT wns=$wns"
