# =====================================================================
# Ventium core synth + place (post-place Fmax) — +VEN_FP_PIPE config (fast-arm FP
# execute pipeline) on top of all 3 iterative engines. Synthesises then runs
# opt/place/phys_opt at a 15 ns (66.7 MHz) target so WNS reads against the goal,
# and reports the post-place worst path (whether the slow-arm f_mem80->fpr cone is
# now the limiter). Routing is skipped (impractically slow at high util); placed
# timing is the Fmax indicator.
#
# Run:  vivado -mode batch -source fpga/scripts/synth_impl_core_fppipe.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/impl_core_fppipe
file mkdir $OUT
set PART xck26-sfvc784-2LV-c

puts "PROBE(core-fppipe): ROOT=$ROOT PART=$PART"
create_project -in_memory -part $PART probe_core_fppipe

set svfiles {
    ventium_pkg.sv
    core/ventium_alu_pkg.sv
    core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv
    core/ventium_sys_pkg.sv
    core/ventium_x87_pkg.sv
    core/core.sv
    core/bpred_btb.sv
    core/decode.sv
    core/issue_uv.sv
    core/ven_idiv.sv
    fpu/fpu_top.sv
    fpu/fpu_srt_div.sv
    fpu/fpu_sqrt_iter.sv
    fpu/ven_bcd.sv
    mem/dcache_timing.sv
    mem/icache.sv
    mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }

set xdc $OUT/core_clk15.xdc
set fh [open $xdc w]
puts $fh "create_clock -period 15.000 -name clk \[get_ports clk\]"
close $fh
read_xdc $xdc

puts "PROBE(core-fppipe): synth_design (+VEN_FP_PIPE +VEN_SRT_ITER +VEN_IDIV_ITER +VEN_BCD_ITER) ..."
synth_design -top core -part $PART \
    -mode out_of_context \
    -include_dirs $RTL/core \
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE} \
    -flatten_hierarchy rebuilt
report_utilization -file $OUT/util_synth.rpt
report_timing_summary -max_paths 10 -delay_type max -file $OUT/timing_synth.rpt
puts "PROBE_CORE_FPPIPE_SYNTH_DONE"

puts "PROBE(core-fppipe): opt_design + place_design + phys_opt_design ..."
opt_design
place_design
phys_opt_design
report_utilization -file $OUT/util_placed.rpt
report_timing_summary -max_paths 20 -delay_type max -file $OUT/timing_placed.rpt
report_timing -max_paths 12 -sort_by group -input_pins -file $OUT/timing_paths_placed.rpt
write_checkpoint -force $OUT/core_fppipe_placed.dcp
puts "PROBE_CORE_FPPIPE_PLACED_DONE"
