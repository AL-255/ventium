# =====================================================================
# +VEN_DEC_PIPE route probe (the de-risked-spike GO/NO-GO). Does moving the 12x32:1
# byte-window MUXF off the eip cone (decode reads the byte-aligned queue: a 4:1/16:1
# extract over flops; the line read + 8:1 word-select are in the registered prefetch)
# DISSOLVE the level-5 congestion and let the core ROUTE LEGALLY below 22 ns? Best config
# + VEN_IC_BRAM (registered line) + VEN_DEC_PIPE. Synth + place + FULL ROUTE at 18 ns
# (a meetable clock with margin; P0-9 proved 15 ns placer estimates lie). Reports F7/F8
# MUXF, congestion, and the routed WNS.
#
# Run:  vivado -mode batch -source fpga/scripts/probe_decpipe.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} { set ROOT [file normalize [file join [file dirname [info script]] .. ..]] }
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/probe_decpipe
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART probe_decpipe

set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }
set xdc $OUT/clk.xdc
set fh [open $xdc w]; puts $fh "create_clock -period 18.000 -name clk \[get_ports clk\]"; close $fh
read_xdc $xdc

synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_BRAM VEN_DEC_PIPE} \
    -flatten_hierarchy rebuilt
report_utilization -file $OUT/util_synth.rpt
report_timing_summary -max_paths 8 -delay_type max -file $OUT/timing_synth.rpt
report_timing -max_paths 12 -nworst 1 -unique_pins -sort_by group -input_pins -delay_type max -file $OUT/paths_synth.rpt
puts "DECPIPE_SYNTH_DONE"
opt_design
place_design -directive AltSpreadLogic_high
phys_opt_design
report_utilization -file $OUT/util_placed.rpt
report_design_analysis -congestion -file $OUT/congestion_placed.rpt
report_timing_summary -max_paths 6 -delay_type max -file $OUT/timing_placed.rpt
puts "DECPIPE_PLACED_DONE"
route_design -directive AlternateCLBRouting
phys_opt_design
report_design_analysis -congestion -file $OUT/congestion_routed.rpt
report_timing_summary -max_paths 8 -delay_type max -file $OUT/timing_routed.rpt
write_checkpoint -force $OUT/core_decpipe_routed.dcp
puts "DECPIPE_ROUTED_DONE"
