# =====================================================================
# Ventium-on-KV260 synthesis FIT/TIMING PROBE
#
# Purpose: measure utilization + estimated Fmax of the AS-IS ventium_soc
# (the DOS-PC platform top) on the KV260 part, with the sim-only DPI elided
# (+define+VTM_NO_DPI). This is a synth-ONLY run (no place & route) to get an
# early read on area and the worst combinational paths (the combinational
# 64-bit integer divide and the 256-bit unrolled x87 FSQRT/FDIV are the
# expected critical paths we plan to make iterative).
#
# Run:  vivado -mode batch -source fpga/scripts/synth_probe.tcl -notrace
# =====================================================================

set ROOT [pwd]
if {![file exists $ROOT/rtl/soc/ventium_soc.sv]} {
    # allow running from anywhere: locate repo root via this script's dir
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/synthprobe
file mkdir $OUT

set PART xck26-sfvc784-2LV-c

puts "PROBE: ROOT=$ROOT PART=$PART"
create_project -in_memory -part $PART probe

# ---- source order: packages first, then modules (mirrors rtl/ventium_soc.f) --
set svfiles {
    ventium_pkg.sv
    core/ventium_alu_pkg.sv
    core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv
    core/ventium_sys_pkg.sv
    core/ventium_x87_pkg.sv
    soc/ventium_soc.sv
    core/core.sv
    core/bpred_btb.sv
    core/decode.sv
    core/issue_uv.sv
    fpu/fpu_top.sv
    mem/dcache_timing.sv
    mem/icache.sv
    mem/tlb.sv
    soc/ven_pic.sv
    soc/ven_pit.sv
    soc/ven_rtc.sv
    soc/ven_i8042.sv
    soc/ven_port92.sv
    soc/ven_vgaregs.sv
    soc/ven_acpipm.sv
    soc/ven_ide.sv
}
foreach f $svfiles {
    puts "PROBE: read_verilog $f"
    read_verilog -sv $RTL/$f
}

read_xdc $ROOT/fpga/constraints/probe.xdc

# core_*.svh are textually `included by core.sv; +incdir+core == rtl/core
puts "PROBE: synth_design starting (this can take many minutes) ..."
synth_design -top ventium_soc -part $PART \
    -mode out_of_context \
    -include_dirs $RTL/core \
    -verilog_define VTM_NO_DPI \
    -flatten_hierarchy rebuilt

puts "PROBE: synth complete — writing reports to $OUT"
report_utilization              -file $OUT/util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $OUT/util_hier.rpt
report_timing_summary -max_paths 15 -delay_type max -file $OUT/timing_summary.rpt
report_timing -max_paths 25 -sort_by group -input_pins -file $OUT/timing_paths.rpt
report_design_analysis -logic_level_distribution \
    -logic_level_dist_paths 1000 -file $OUT/logic_levels.rpt
write_checkpoint -force $OUT/ventium_soc_synth.dcp

puts "PROBE_DONE"
