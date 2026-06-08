# =====================================================================
# P0-11 PREDECODE-ON-FILL µop-cache synth probe (+VEN_IC_BRAM +VEN_UOPCACHE).
#
# THE decisive measurement: does deleting the twelve 32:1 byte selects (the
# ub[]/vb[] gather) from the fast path — replacing it with a registered slot read
# fed by predecode-on-fill — COLLAPSE the MUXF7/MUXF8 band, or is the MUXF
# "conserved" a 4th time (as it was under BRAM P0-3 / decode-pipe P0-10)?
#
# Reports MUXF7/MUXF8 + LUT + RAMB/URAM + synth WNS, then opt+place for the
# congestion level. Compare MUXF7/MUXF8 against the narrowb baseline (14457 F7 /
# 6202 F8). Synth-only first (fast); place is the congestion judge.
#
# Run:  vivado -mode batch -source fpga/scripts/synth_paths_uopcache.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/paths_uopcache
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART probe_paths_uopcache

set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/uopcache.sv mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }
set xdc $OUT/clk15.xdc
set fh [open $xdc w]; puts $fh "create_clock -period 15.000 -name clk \[get_ports clk\]"; close $fh
read_xdc $xdc

synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_BRAM VEN_UOPCACHE} \
    -flatten_hierarchy rebuilt
report_utilization -file $OUT/util_synth.rpt
report_timing_summary -max_paths 10 -delay_type max -file $OUT/timing_summary.rpt
report_timing -max_paths 30 -nworst 1 -unique_pins -sort_by group -input_pins \
    -delay_type max -file $OUT/timing_paths_distinct.rpt

# echo the headline MUXF/LUT/RAMB/URAM numbers to stdout for a quick read.
set f7 [llength [get_cells -hier -filter {REF_NAME == MUXF7 || PRIMITIVE_SUBGROUP == muxfx && REF_NAME == MUXF7}]]
set f8 [llength [get_cells -hier -filter {REF_NAME == MUXF8}]]
set f9 [llength [get_cells -hier -filter {REF_NAME == MUXF9}]]
puts "UOPCACHE_MUXF7=$f7"
puts "UOPCACHE_MUXF8=$f8"
puts "UOPCACHE_MUXF9=$f9"
puts "UOPCACHE_SYNTH_DONE"

opt_design
place_design -directive AltSpreadLogic_high
report_design_analysis -congestion -file $OUT/congestion_placed.rpt
report_timing_summary -max_paths 4 -delay_type max -file $OUT/timing_placed.rpt
puts "UOPCACHE_PLACED_DONE"
