# =====================================================================
# Ventium CORE-only synthesis FIT/TIMING PROBE (out-of-context)
#
# Synthesizes just `core` (the CPU spine + icache/dcache_timing/tlb/fpu_top/
# bpred_btb/decode/issue_uv) — the dominant area/timing consumer. Excludes the
# SoC peripherals, biu_p5, and the IDE disk[] array (all small or being
# replaced), so we get a clean read on the core + x87 FPU + caches.
#
# Run:  vivado -mode batch -source fpga/scripts/synth_probe_core.tcl -notrace
# =====================================================================

set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/synthprobe_core
file mkdir $OUT
set PART xck26-sfvc784-2LV-c

puts "PROBE(core): ROOT=$ROOT PART=$PART"
create_project -in_memory -part $PART probe_core

# packages first, then the core + its leaf modules (no soc/, no bus/, no top)
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
    mem/dcache_timing.sv
    mem/icache.sv
    mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }

# 100 MHz target clock on the core's `clk` so post-synth WNS => Fmax estimate
set xdc $OUT/core_clk.xdc
set fh [open $xdc w]
puts $fh "create_clock -period 10.000 -name clk \[get_ports clk\]"
close $fh
read_xdc $xdc

puts "PROBE(core): synth_design starting ..."
synth_design -top core -part $PART \
    -mode out_of_context \
    -include_dirs $RTL/core \
    -verilog_define VTM_NO_DPI \
    -flatten_hierarchy rebuilt

report_utilization               -file $OUT/util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $OUT/util_hier.rpt
report_timing_summary -max_paths 20 -delay_type max -file $OUT/timing_summary.rpt
report_timing -max_paths 30 -sort_by group -input_pins -file $OUT/timing_paths.rpt
write_checkpoint -force $OUT/core_synth.dcp
puts "PROBE_CORE_DONE"
