# =====================================================================
# Ventium CORE-only synth probe — ITERATIVE SRT FDIV/FSQRT build (+VEN_SRT_ITER).
#
# Same as synth_probe_core.tcl but adds the iterative engine modules and defines
# VEN_SRT_ITER, so the combinational fx_srt_div / fx_isqrt loops are stubbed (D8b)
# and the engines carry the divide/sqrt. Compare util.rpt / timing_summary.rpt
# against fpga/build/synthprobe_core/ to measure the LUT/CARRY8 collapse + Fmax.
#
# Run:  vivado -mode batch -source fpga/scripts/synth_probe_core_iter.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/synthprobe_core_iter
file mkdir $OUT
set PART xck26-sfvc784-2LV-c

puts "PROBE(core-iter): ROOT=$ROOT PART=$PART"
create_project -in_memory -part $PART probe_core_iter

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
    fpu/fpu_top.sv
    fpu/fpu_srt_div.sv
    fpu/fpu_sqrt_iter.sv
    mem/dcache_timing.sv
    mem/icache.sv
    mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }

set xdc $OUT/core_clk.xdc
set fh [open $xdc w]
puts $fh "create_clock -period 10.000 -name clk \[get_ports clk\]"
close $fh
read_xdc $xdc

puts "PROBE(core-iter): synth_design starting (+VEN_SRT_ITER) ..."
synth_design -top core -part $PART \
    -mode out_of_context \
    -include_dirs $RTL/core \
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER} \
    -flatten_hierarchy rebuilt

report_utilization               -file $OUT/util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $OUT/util_hier.rpt
report_timing_summary -max_paths 20 -delay_type max -file $OUT/timing_summary.rpt
report_timing -max_paths 30 -sort_by group -input_pins -file $OUT/timing_paths.rpt
write_checkpoint -force $OUT/core_iter_synth.dcp
puts "PROBE_CORE_ITER_DONE"
