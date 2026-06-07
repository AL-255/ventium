# =====================================================================
# Synth-only path-SPECTRUM probe for the full pipelined config (+VEN_FP_PIPE +
# all iter engines, incl. the iterative FBLD ven_bcd_to_fp). With FBLD's cone
# removed, this reveals the SECONDARY critical paths (report_timing -unique_pins
# -nworst gives DISTINCT cones, not N endpoints of one cone). Synth-only (no
# place) — fast; 15 ns target so slack reads against 66.7 MHz.
#
# Run:  vivado -mode batch -source fpga/scripts/synth_paths_btbpipe.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/paths_btbpipe
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART probe_paths_btbpipe

set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }
set xdc $OUT/clk15.xdc
set fh [open $xdc w]; puts $fh "create_clock -period 15.000 -name clk \[get_ports clk\]"; close $fh
read_xdc $xdc

synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE} \
    -flatten_hierarchy rebuilt
report_utilization -file $OUT/util.rpt
report_timing_summary -max_paths 10 -delay_type max -file $OUT/timing_summary.rpt
# DISTINCT cones: -unique_pins => at most one path per unique pin set; -nworst 1
# per endpoint; many paths so secondary cones surface past the worst.
report_timing -max_paths 40 -nworst 1 -unique_pins -sort_by group -input_pins \
    -delay_type max -file $OUT/timing_paths_distinct.rpt
puts "PROBE_PATHS_FPPIPE_DONE"
