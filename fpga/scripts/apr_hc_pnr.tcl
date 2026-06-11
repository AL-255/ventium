# =====================================================================
# Half-cache TIMING-DRIVEN P&R strategy runner (K26 / xck26).
#
# The half-cache config SYNTHS at ~59 MHz but the production apr_run.tcl flow
# (place AltSpreadLogic_high + route AlternateCLBRouting -- CONGESTION directives
# tuned for the full, congestion-bound cache) ROUTES it at only ~50 MHz: those
# directives SPREAD the fpp_b->fpr FP-commit cone (78 levels / 43 CARRY8, route
# 58%) and inflate its route delay ~3 ns. With half the cache the die is no longer
# broadly congestion-bound, so TIMING-driven P&R should recover that gap.
#
# Two stages, so the (expensive) synth runs ONCE and every strategy P&Rs from the
# same checkpoint:
#
#   STAGE=synth : build half-cache OOC for $PART, opt_design, write $DCP + synth
#                 utilization/timing.  Run this first.
#   STAGE=pnr   : open $DCP, constrain to CLOCK_NS, then
#                 place_design -directive $PLACE_DIR
#                 phys_opt_design -directive $PHYSOPT_DIR   (skip if empty)
#                 route_design -directive $ROUTE_DIR
#                 phys_opt_design -directive $POSTROUTE_DIR  (skip if empty)
#                 and report routed WNS + congestion into fpga/build/strathc/$STRAT.
#
# Env:
#   STAGE        synth | pnr            (default synth)
#   STRAT        strategy label / outdir name (pnr)        (default s_default)
#   CLOCK_NS     clock period ns to constrain to (pnr)     (default 15)
#   PLACE_DIR    place_design -directive                   (default Explore)
#   PHYSOPT_DIR  post-place phys_opt_design -directive ("" = skip)  (default AggressiveExplore)
#   ROUTE_DIR    route_design -directive                   (default Explore)
#   POSTROUTE_DIR post-route phys_opt_design -directive ("" = skip) (default AggressiveExplore)
#   THREADS      Vivado maxThreads                          (default 6)
#   PART         FPGA part                                  (default xck26-sfvc784-2LV-c)
#
# Run (synth once):
#   STAGE=synth vivado -mode batch -source fpga/scripts/apr_hc_pnr.tcl -notrace
# Run (one strategy):
#   STAGE=pnr STRAT=s1_timingopt PLACE_DIR=ExtraTimingOpt ROUTE_DIR=Explore \
#     vivado -mode batch -source fpga/scripts/apr_hc_pnr.tcl -notrace
# =====================================================================
proc env_or {n d} { if {[info exists ::env($n)] && $::env($n) ne ""} { return $::env($n) } else { return $d } }

set STAGE        [env_or STAGE        synth]
set STRAT        [env_or STRAT        s_default]
set CLOCK_NS     [env_or CLOCK_NS     15]
set PLACE_DIR    [env_or PLACE_DIR    Explore]
set PHYSOPT_DIR  [env_or PHYSOPT_DIR  AggressiveExplore]
set ROUTE_DIR    [env_or ROUTE_DIR    Explore]
set POSTROUTE_DIR [env_or POSTROUTE_DIR AggressiveExplore]
set THREADS      [env_or THREADS      6]
set PART         [env_or PART         xck26-sfvc784-2LV-c]
# DCP_IN: which synth checkpoint the pnr stage P&Rs (lets a retimed-synth dcp feed
# the same strategy panel). PBLOCK: a clock-region range string -> a hard Pblock is
# created for the FP group {u_fpu_state + fpp_* + fp-commit cone} before placement.
set DCP_IN       [env_or DCP_IN       ""]
set PBLOCK       [env_or PBLOCK       ""]
set_param general.maxThreads $THREADS

set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} { set ROOT [file normalize [file join [file dirname [info script]] .. ..]] }
set RTL  $ROOT/rtl
set BASE $ROOT/fpga/build/strathc
file mkdir $BASE

# ---- the half-cache config = production "uopcache" DEFS + VEN_CACHE_HALF -------
set DEFS {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_BRAM VEN_UOPCACHE VEN_CACHE_HALF}
# FP_PIPE2=1 adds the 2-stage FP-commit split (+VEN_FP_PIPE2): inserts a register at
# the f_eval_s1/f_eval_s2 boundary so the ~80-level FADD-commit cone halves. Proven
# cycle-safe (verif/fppipe/run-fp-pipe2-ab.sh: faddchain cycle-identical, fpindep
# +0.09% within band, identical final arch state; make verify GREEN). The dcp/out
# get a _fp2 tag so they never clobber the 1-stage build.
set FP2 [env_or FP_PIPE2 0]
set SUF ""
if {$FP2} { lappend DEFS VEN_FP_PIPE2 ; set SUF "_fp2" }
set DCP  $BASE/core_synth_hc${SUF}.dcp

set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/uopcache.sv mem/tlb.sv
}

# STAGE=synth_rt : same OOC build but with GLOBAL RETIMING enabled. Retiming is
# behaviour-preserving (same per-cycle I/O), so it is CYCLE-SAFE -- the Verilator
# model uses the un-retimed RTL, so make verify / the cycle bands are untouched;
# only the FPGA netlist is rebalanced. The fpp(single-fanout) -> [78 levels] -> fpr
# FP-commit cone is the retiming target. Writes core_synth_hc_rt.dcp.
if {$STAGE eq "synth_rt"} {
    create_project -in_memory -part $PART hc_synth_rt
    foreach f $svfiles { read_verilog -sv $RTL/$f }
    set xdc $BASE/clk_rt.xdc
    set fh [open $xdc w]; puts $fh "create_clock -period $CLOCK_NS -name clk \[get_ports clk\]"; close $fh
    read_xdc $xdc
    synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
        -verilog_define $DEFS -flatten_hierarchy rebuilt -retiming
    opt_design
    report_utilization -file $BASE/util_synth_rt.rpt
    report_timing_summary -max_paths 8 -delay_type max -file $BASE/timing_synth_rt.rpt
    write_checkpoint -force $BASE/core_synth_hc_rt.dcp
    puts "HC_SYNTH_RT_DONE dcp=$BASE/core_synth_hc_rt.dcp"
    exit
}

if {$STAGE eq "synth"} {
    create_project -in_memory -part $PART hc_synth
    foreach f $svfiles { read_verilog -sv $RTL/$f }
    set xdc $BASE/clk.xdc
    set fh [open $xdc w]; puts $fh "create_clock -period $CLOCK_NS -name clk \[get_ports clk\]"; close $fh
    read_xdc $xdc
    synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
        -verilog_define $DEFS -flatten_hierarchy rebuilt
    opt_design
    report_utilization -file $BASE/util_synth.rpt
    report_timing_summary -max_paths 8 -delay_type max -file $BASE/timing_synth.rpt
    write_checkpoint -force $DCP
    puts "HC_SYNTH_DONE dcp=$DCP"
    exit
}

# ---- STAGE=pnr : one strategy from a synth checkpoint -------------------------
if {$DCP_IN eq ""} { set DCP_IN $DCP }
set OUT $BASE/$STRAT
file mkdir $OUT
puts "HC_PNR $STRAT : dcp=$DCP_IN clock=${CLOCK_NS}ns place='$PLACE_DIR' physopt='$PHYSOPT_DIR' route='$ROUTE_DIR' postroute='$POSTROUTE_DIR' pblock='$PBLOCK' threads=$THREADS"
open_checkpoint $DCP_IN

# constrain to the requested period (the checkpoint may carry a different one)
set cx $OUT/clk.xdc
set fh [open $cx w]; puts $fh "create_clock -period $CLOCK_NS -name clk \[get_ports clk\]"; close $fh
read_xdc $cx

# ---- optional FP-group Pblock: cluster the FP-commit cone so the feeder routes
# into the 43-deep carry chain + the fpr write collapse. Generously sized so the
# group is not over-packed (local over-utilisation would re-introduce congestion).
if {$PBLOCK ne ""} {
    create_pblock pb_fp
    resize_pblock pb_fp -add $PBLOCK
    set n 0
    set u [get_cells -quiet u_fpu_state]
    if {[llength $u]} { add_cells_to_pblock pb_fp $u ; incr n [llength $u] }
    foreach pat {*fpp_a_reg* *fpp_b_reg* *fpp_aluop_reg* *fpp_rc_reg* *fpp_err_reg* *fp_wabs*} {
        set c [get_cells -hier -quiet -filter "NAME =~ $pat"]
        if {[llength $c]} { add_cells_to_pblock pb_fp $c ; incr n [llength $c] }
    }
    puts "PBLOCK pb_fp = $PBLOCK ; cells=$n"
    report_utilization -pblocks [get_pblocks pb_fp] -file $OUT/util_pblock.rpt
}

place_design -directive $PLACE_DIR
if {$PHYSOPT_DIR ne ""} { phys_opt_design -directive $PHYSOPT_DIR }
# FANOUT_REPL=1: placement-aware replication of the high-fanout uopcache-fill ->
# icache-LRU nets (the store_bmap -> ic_age cluster routes 65-73 % because one driver
# fans out to every icache set). Replicating per placement cluster shortens those
# routes — cycle-neutral (same logic, duplicated drivers).
if {[env_or FANOUT_REPL 0]} {
    set hi [get_nets -hier -quiet -filter {FLAT_PIN_COUNT > 80 && (NAME =~ *store_bmap* || NAME =~ *store_slots* || NAME =~ *ic_age* || NAME =~ *uop*)}]
    puts "FANOUT_REPL: [llength $hi] high-fanout uopcache/icache nets"
    if {[llength $hi] > 0} { catch { phys_opt_design -force_replication_on_nets $hi } }
}
report_design_analysis -congestion -file $OUT/congestion_placed.rpt
report_timing_summary -max_paths 4 -delay_type max -file $OUT/timing_placed.rpt
puts "HC_PNR_PLACED_DONE $STRAT"

route_design -directive $ROUTE_DIR
if {$POSTROUTE_DIR ne ""} { phys_opt_design -directive $POSTROUTE_DIR }
report_design_analysis -congestion -file $OUT/congestion_routed.rpt
report_timing_summary -max_paths 8 -delay_type max -file $OUT/timing_routed.rpt
report_timing -max_paths 6 -nworst 2 -unique_pins -input_pins -file $OUT/timing_paths_routed.rpt
write_checkpoint -force $OUT/routed.dcp
puts "HC_PNR_ROUTED_DONE $STRAT"
