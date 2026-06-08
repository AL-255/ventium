# =====================================================================
# Synthesize the BEST RTL config (narrowB) ONCE and write a post-synth checkpoint,
# so the Vivado strategy sweep can reopen it and try different place/route/phys_opt
# directives WITHOUT re-synthesizing each time. Synth-side strategies (different
# synth_design directives / -no_lc / -flatten none / retiming) still need a fresh
# synth; the place+route strategies reuse this checkpoint.
#
# Run:  vivado -mode batch -source fpga/scripts/synth_once_checkpoint.tcl -notrace
# Output: fpga/build/strat/core_synth.dcp
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/strat
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART strat_synth

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
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_NARROWB} \
    -flatten_hierarchy rebuilt
report_utilization -file $OUT/util_synth.rpt
report_timing_summary -max_paths 4 -delay_type max -file $OUT/timing_synth.rpt
write_checkpoint -force $OUT/core_synth.dcp
puts "STRAT_SYNTH_CHECKPOINT_DONE"
