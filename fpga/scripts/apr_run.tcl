# =====================================================================
# Full synth -> place -> route APR run (parameterized). Produces the headline
# util/timing/congestion numbers + a routed checkpoint, and dumps the per-module
# placed-cell CSV for the colored device view.
#
# Env:
#   CONFIG = narrowb | uopcache   (define set)
#   MODE   = full | view          (full = flatten rebuilt + ROUTE; view = flatten
#                                   none + place only, for true module-color CSV)
#   CLK    = clock period ns (default 15)
#
# Run: CONFIG=narrowb MODE=full vivado -mode batch -source fpga/scripts/apr_run.tcl -notrace
# =====================================================================
proc env_or {n d} { if {[info exists ::env($n)] && $::env($n) ne ""} { return $::env($n) } else { return $d } }
set CONFIG [env_or CONFIG narrowb]
set MODE   [env_or MODE   full]
set CLK    [env_or CLK    15]
set PART   [env_or PART   xck26-sfvc784-2LV-c]
# OUTTAG lets a non-default PART write to its own build dir (e.g. apr_narrowb_full_zu15eg)
set OUTTAG [env_or OUTTAG ""]

set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} { set ROOT [file normalize [file join [file dirname [info script]] .. ..]] }
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/apr_${CONFIG}_${MODE}${OUTTAG}
file mkdir $OUT
create_project -in_memory -part $PART apr_${CONFIG}_${MODE}

set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/uopcache.sv mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }
set xdc $OUT/clk.xdc
set fh [open $xdc w]; puts $fh "create_clock -period $CLK -name clk \[get_ports clk\]"; close $fh
read_xdc $xdc

if {$CONFIG eq "uopcache"} {
    set DEFS {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_BRAM VEN_UOPCACHE}
} else {
    set DEFS {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_NARROWB}
}
set FLAT [expr {$MODE eq "view" ? "none" : "rebuilt"}]

synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
    -verilog_define $DEFS -flatten_hierarchy $FLAT
report_utilization -file $OUT/util_synth.rpt
report_timing_summary -max_paths 8 -delay_type max -file $OUT/timing_synth.rpt
puts "APR_${CONFIG}_${MODE}_SYNTH_DONE"

opt_design
place_design -directive AltSpreadLogic_high
phys_opt_design
report_utilization -file $OUT/util_placed.rpt
report_timing_summary -max_paths 8 -delay_type max -file $OUT/timing_placed.rpt
report_design_analysis -congestion -file $OUT/congestion_placed.rpt
write_checkpoint -force $OUT/placed.dcp
puts "APR_${CONFIG}_${MODE}_PLACED_DONE"

# ---- per-module placed-cell CSV (colored device view) ---------------------
set fh [open $OUT/cells_loc.csv w]
puts $fh "module,x,y"
set n 0
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE==1}] {
    set loc [get_property LOC $c]
    if {$loc eq ""} continue
    if {![regexp {[A-Z_]+X([0-9]+)Y([0-9]+)} $loc -> x y]} continue
    set nm [get_property NAME $c]
    if {[regexp {^(u_[A-Za-z0-9_]+)/} $nm -> inst]} { set mod $inst } else { set mod "core_spine" }
    puts $fh "$mod,$x,$y"; incr n
}
close $fh
puts "APR_${CONFIG}_${MODE}_CSV_DONE cells=$n"

if {$MODE eq "full"} {
    # full route to convergence + routed reports.
    route_design -directive AlternateCLBRouting
    phys_opt_design
    report_timing_summary -max_paths 12 -delay_type max -file $OUT/timing_routed.rpt
    report_design_analysis -congestion -file $OUT/congestion_routed.rpt
    report_utilization -file $OUT/util_routed.rpt
    write_checkpoint -force $OUT/routed.dcp
    puts "APR_${CONFIG}_${MODE}_ROUTED_DONE"
}
puts "APR_${CONFIG}_${MODE}_DONE"
