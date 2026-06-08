# =====================================================================
# Full-core synth+place probe for the BRAM icache front-end (+VEN_IC_BRAM). The
# PAYOFF measurement: does moving ic_line into RAMB36 (dissolving the distributed-RAM
# 256:1 read-mux MUXF) actually lift the PLACED Fmax / relieve the level-5 99%-u_icache
# congestion wall (TIMING_PROBLEMS.md P0-7)? Reports RAMB usage + MUXF + placed WNS +
# congestion. Best config + VEN_IC_BRAM (BRAM supersedes VEN_IC_NARROWB).
#
# Run:  vivado -mode batch -source fpga/scripts/synth_paths_icbram.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/paths_icbram
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART probe_icbram

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
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_BRAM} \
    -flatten_hierarchy rebuilt
report_utilization -file $OUT/util_synth.rpt
report_timing_summary -max_paths 10 -delay_type max -file $OUT/timing_synth.rpt
report_timing -max_paths 20 -nworst 1 -unique_pins -sort_by group -input_pins \
    -delay_type max -file $OUT/timing_paths_distinct.rpt
puts "ICBRAM_SYNTH_DONE"
opt_design
place_design -directive AltSpreadLogic_high
phys_opt_design
report_utilization -file $OUT/util_placed.rpt
report_design_analysis -congestion -file $OUT/congestion_placed.rpt
report_timing_summary -max_paths 6 -delay_type max -file $OUT/timing_placed.rpt
puts "ICBRAM_PLACED_DONE"
