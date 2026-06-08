# =====================================================================
# Congestion-driven implementation. The congestion analysis showed the route
# fails on LEVEL-5 congestion that is 99% u_icache MUXF (F7/F8 read-mux trees),
# and every module is already spread full-die — so the lever is congestion-driven
# PLACEMENT (AltSpreadLogic_high spreads the congested logic harder, trading
# wirelength for routability) + alternate-CLB routing, NOT a Pblock. Uses a
# meetable 22 ns clock so the route CONVERGES (the 15 ns target made the router
# spin forever). Reports post-place congestion + the routed Fmax.
#
# Run:  vivado -mode batch -source fpga/scripts/impl_floorplan.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/impl_floorplan
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART fp

set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }
set xdc $OUT/clk.xdc
set fh [open $xdc w]; puts $fh "create_clock -period 22.000 -name clk \[get_ports clk\]"; close $fh
read_xdc $xdc

synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_NARROWB} \
    -flatten_hierarchy rebuilt
opt_design
puts "FLOORPLAN: place_design -directive AltSpreadLogic_high ..."
place_design -directive AltSpreadLogic_high
phys_opt_design
report_design_analysis -congestion -file $OUT/congestion_placed.rpt
report_timing_summary -max_paths 6 -delay_type max -file $OUT/timing_placed.rpt
puts "FLOORPLAN_PLACED_DONE"
puts "FLOORPLAN: route_design -directive AlternateCLBRouting ..."
route_design -directive AlternateCLBRouting
phys_opt_design
report_design_analysis -congestion -file $OUT/congestion_routed.rpt
report_timing_summary -max_paths 16 -delay_type max -file $OUT/timing_routed.rpt
report_timing -max_paths 12 -nworst 1 -unique_pins -sort_by group -input_pins -file $OUT/timing_paths_routed.rpt
write_checkpoint -force $OUT/core_floorplan_routed.dcp
puts "FLOORPLAN_ROUTED_DONE"
