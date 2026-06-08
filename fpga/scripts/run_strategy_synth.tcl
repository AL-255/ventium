# =====================================================================
# Full-flow Vivado strategy runner for SYNTH-SIDE strategies (those that change the
# netlist and so need a fresh synth, not the checkpoint): synth_design -directive
# AlternateRoutability (rank 3), -flatten_hierarchy none (rank 7), MUXF_MAPPING, etc.
# Then place+route at a meetable clock and report routed WNS + congestion.
#
# Env vars:
#   STRAT_NAME      - output dir label
#   SYNTH_DIRECTIVE - synth_design -directive (empty = default)
#   SYNTH_FLATTEN   - -flatten_hierarchy value (default rebuilt)
#   CLOCK_NS        - clock period (default 18)
#   PLACE_DIR       - place_design -directive (default AltSpreadLogic_high)
#   PHYSOPT_DIR     - phys_opt_design -directive (default AggressiveExplore)
#   ROUTE_DIR       - route_design -directive (default Explore)
#   OPT_MUXF_REMAP  - 1 = opt_design -muxf_remap before place
#
# Run:  STRAT_NAME=altroute SYNTH_DIRECTIVE=AlternateRoutability \
#         vivado -mode batch -source fpga/scripts/run_strategy_synth.tcl -notrace
# =====================================================================
proc env_or {name def} { if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) } else { return $def } }
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} { set ROOT [file normalize [file join [file dirname [info script]] .. ..]] }
set RTL  $ROOT/rtl
set NAME [env_or STRAT_NAME synthstrat]
set OUT  $ROOT/fpga/build/strat/$NAME
file mkdir $OUT
set PART xck26-sfvc784-2LV-c

set SYNTH_DIRECTIVE [env_or SYNTH_DIRECTIVE ""]
set SYNTH_FLATTEN   [env_or SYNTH_FLATTEN rebuilt]
set CLOCK_NS        [env_or CLOCK_NS 18]
set PLACE_DIR       [env_or PLACE_DIR AltSpreadLogic_high]
set PHYSOPT_DIR     [env_or PHYSOPT_DIR AggressiveExplore]
set ROUTE_DIR       [env_or ROUTE_DIR Explore]
set OPT_MUXF        [env_or OPT_MUXF_REMAP 0]

create_project -in_memory -part $PART strat_$NAME
set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }
set cx $OUT/clk.xdc
set fh [open $cx w]; puts $fh "create_clock -period $CLOCK_NS -name clk \[get_ports clk\]"; close $fh
read_xdc $cx

set defs {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_NARROWB}
puts "SYNTHSTRAT $NAME : directive='$SYNTH_DIRECTIVE' flatten=$SYNTH_FLATTEN clk=$CLOCK_NS place=$PLACE_DIR muxf_remap=$OPT_MUXF"
if {$SYNTH_DIRECTIVE ne ""} {
    synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
        -directive $SYNTH_DIRECTIVE -verilog_define $defs -flatten_hierarchy $SYNTH_FLATTEN
} else {
    synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
        -verilog_define $defs -flatten_hierarchy $SYNTH_FLATTEN
}
report_utilization -file $OUT/util_synth.rpt
report_timing_summary -max_paths 2 -delay_type max -file $OUT/timing_synth.rpt
puts "SYNTHSTRAT_SYNTH_DONE $NAME"

if {$OPT_MUXF == 1} { opt_design -muxf_remap } else { opt_design }
place_design -directive $PLACE_DIR
phys_opt_design -directive $PHYSOPT_DIR
report_design_analysis -congestion -file $OUT/congestion_placed.rpt
report_timing_summary -max_paths 4 -delay_type max -file $OUT/timing_placed.rpt
puts "SYNTHSTRAT_PLACED_DONE $NAME"
route_design -directive $ROUTE_DIR
phys_opt_design
report_design_analysis -congestion -file $OUT/congestion_routed.rpt
report_timing_summary -max_paths 6 -delay_type max -file $OUT/timing_routed.rpt
puts "STRAT_ROUTED_DONE $NAME"
puts "STRAT_DONE $NAME"
