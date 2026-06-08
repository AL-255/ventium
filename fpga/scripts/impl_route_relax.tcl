# =====================================================================
# FULL place & ROUTE of the best pipelined config (+VEN_FP_PIPE +VEN_BTB_PIPE +
# all iter engines) to get the TRUE post-ROUTE Fmax — the synth/placed numbers
# are pre-route estimates; the routing wall only shows after route_design. Uses
# timing-aggressive directives (ExtraTimingOpt place, Explore route) + phys_opt.
# Optional Pblock floorplan: set env VEN_PBLOCK=1 to constrain the core to a
# compact contiguous region (forces the placer to keep hot nets local).
#
# +VEN_BTB_PIPE is listed as a REMOVABLE define (drop it here to disable the BTB
# update pipeline independently if it ever misbehaves on hardware).
#
# Run:  vivado -mode batch -source fpga/scripts/impl_route_fppipe_relax.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set PBLOCK [expr {[info exists ::env(VEN_PBLOCK)] && $::env(VEN_PBLOCK) eq "1"}]
set OUT  $ROOT/fpga/build/[expr {$PBLOCK ? "route_fppipe_relax_pblock" : "route_fppipe_relax"}]
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART probe_route_fppipe_relax

set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }
set xdc $OUT/clk22.xdc
set fh [open $xdc w]; puts $fh "create_clock -period 22.000 -name clk \[get_ports clk\]"; close $fh
read_xdc $xdc

# +VEN_BTB_PIPE here ↓ is the removable BTB-pipeline option.
synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE} \
    -flatten_hierarchy rebuilt
report_utilization -file $OUT/util_synth.rpt
puts "ROUTE_FPPIPE_SYNTH_DONE"

if {$PBLOCK} {
    # Compact contiguous floorplan: pack the whole core into the lower-left-biased
    # clock regions so eip->eip and f_mem80->fpr nets stay short (vs the OOC placer
    # spreading the 82%-full design across the whole die to ease congestion).
    puts "ROUTE_FPPIPE: applying Pblock floorplan ..."
    create_pblock pb_core
    add_cells_to_pblock pb_core [get_cells -hierarchical -filter {PRIMITIVE_LEVEL!=INTERNAL}] -quiet
    resize_pblock pb_core -add {SLICE_X0Y0:SLICE_X111Y239}
    set_property IS_SOFT TRUE [get_pblocks pb_core]
}

opt_design
puts "ROUTE_FPPIPE: place_design (ExtraTimingOpt) ..."
place_design -directive ExtraTimingOpt
phys_opt_design
report_timing_summary -max_paths 6 -delay_type max -file $OUT/timing_placed.rpt
puts "ROUTE_FPPIPE_PLACED_DONE"
puts "ROUTE_FPPIPE: route_design (default directive — faster than Explore) ..."
route_design
report_utilization -file $OUT/util_routed.rpt
report_timing_summary -max_paths 20 -delay_type max -file $OUT/timing_routed.rpt
report_timing -max_paths 16 -nworst 1 -unique_pins -sort_by group -input_pins -file $OUT/timing_paths_routed.rpt
puts "ROUTE_FPPIPE_ROUTED_DONE"
