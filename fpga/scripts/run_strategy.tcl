# =====================================================================
# Parameterized Vivado place+route STRATEGY runner for the congestion sweep. Reopens
# the pre-synthesized checkpoint (fpga/build/strat/core_synth.dcp) and applies one
# place/phys_opt/route strategy passed via environment variables, then reports the
# PLACED and ROUTED WNS + congestion. Reusing the checkpoint avoids re-synthesis per
# strategy (synth-side strategies use a separate full-flow script).
#
# Env vars (all optional except STRAT_NAME):
#   STRAT_NAME   - label for the output dir (fpga/build/strat/<name>)
#   OPT_DIR      - opt_design -directive  (empty = plain opt_design)
#   PLACE_DIR    - place_design -directive (default Default)
#   PHYSOPT_DIR  - phys_opt_design -directive (empty = skip post-place phys_opt)
#   ROUTE_DIR    - route_design -directive (empty = skip route, placed-only)
#   POSTROUTE_PO - 1 = run a post-route phys_opt_design
#
# Run:  STRAT_NAME=foo PLACE_DIR=Explore ROUTE_DIR=Explore \
#         vivado -mode batch -source fpga/scripts/run_strategy.tcl -notrace
# =====================================================================
proc env_or {name def} { if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) } else { return $def } }

set ROOT [pwd]
if {![file exists $ROOT/fpga/build/strat/core_synth.dcp]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set DCP  $ROOT/fpga/build/strat/core_synth.dcp
set NAME [env_or STRAT_NAME strat]
set OUT  $ROOT/fpga/build/strat/$NAME
file mkdir $OUT

set OPT_DIR     [env_or OPT_DIR ""]
set OPT_MUXF    [env_or OPT_MUXF_REMAP 0]
set PLACE_DIR   [env_or PLACE_DIR Default]
set PHYSOPT_DIR [env_or PHYSOPT_DIR ""]
set ROUTE_DIR   [env_or ROUTE_DIR ""]
set POSTROUTE_PO [env_or POSTROUTE_PO 0]
set CLOCK_NS    [env_or CLOCK_NS ""]
set FANOUT_REPL [env_or FANOUT_REPL 0]

puts "STRATEGY $NAME : opt='$OPT_DIR' muxf_remap=$OPT_MUXF place='$PLACE_DIR' physopt='$PHYSOPT_DIR' route='$ROUTE_DIR' postroute_po=$POSTROUTE_PO clock_ns='$CLOCK_NS' fanout_repl=$FANOUT_REPL"
open_checkpoint $DCP

# re-constrain to a (meetable) clock period so the routed WNS is honest, not a
# non-converging 15 ns chase (the strategy panel's methodology note).
if {$CLOCK_NS ne ""} {
    set cx $OUT/clk.xdc
    set fh [open $cx w]; puts $fh "create_clock -period $CLOCK_NS -name clk \[get_ports clk\]"; close $fh
    read_xdc $cx
}

# opt_design: -muxf_remap demotes the un-spreadable F7/F8 byte-window mux trees to
# placeable LUT3s (rank-1 lever); a directive and the remap can both apply.
if {$OPT_DIR ne "" && $OPT_MUXF == 1} { opt_design -directive $OPT_DIR -muxf_remap \
} elseif {$OPT_DIR ne ""} { opt_design -directive $OPT_DIR \
} elseif {$OPT_MUXF == 1} { opt_design -muxf_remap \
} else { opt_design }
place_design -directive $PLACE_DIR
if {$PHYSOPT_DIR ne ""} { phys_opt_design -directive $PHYSOPT_DIR }
# rank-4: placement-aware replication of the high-fanout byte-window select drivers
# (flin[4:0]/u_d.len fan out to thousands of MUXF sinks from one CLB -> long routes).
if {$FANOUT_REPL == 1} {
    set hi [get_nets -hier -filter {FLAT_PIN_COUNT > 150 && (NAME =~ *flin* || NAME =~ *u_d* || NAME =~ *ic_rd* )} -quiet]
    puts "FANOUT_REPL: [llength $hi] high-fanout select nets"
    if {[llength $hi] > 0} { catch { phys_opt_design -force_replication_on_nets $hi } }
}
report_design_analysis -congestion -file $OUT/congestion_placed.rpt
report_timing_summary -max_paths 4 -delay_type max -file $OUT/timing_placed.rpt
puts "STRAT_PLACED_DONE $NAME"

if {$ROUTE_DIR ne ""} {
    route_design -directive $ROUTE_DIR
    if {$POSTROUTE_PO == 1} { phys_opt_design }
    report_design_analysis -congestion -file $OUT/congestion_routed.rpt
    report_timing_summary -max_paths 6 -delay_type max -file $OUT/timing_routed.rpt
    puts "STRAT_ROUTED_DONE $NAME"
}
puts "STRAT_DONE $NAME"
