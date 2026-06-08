# Quick single-run LUT/DSP/CARRY measurement (flatten none, +VEN_UOPCACHE config).
# Used to measure incremental area changes vs the 89,634 LUT / 31 DSP baseline.
# Run: vivado -mode batch -source fpga/scripts/probe_lut_quick.tcl -notrace
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} { set ROOT [file normalize [file join [file dirname [info script]] .. ..]] }
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/lut_quick
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART probe_lut_quick
set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/uopcache.sv mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }
set xdc $OUT/clk15.xdc
set fh [open $xdc w]; puts $fh "create_clock -period 15.000 -name clk \[get_ports clk\]"; close $fh
read_xdc $xdc
synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_BRAM VEN_UOPCACHE} \
    -flatten_hierarchy none
report_utilization -file $OUT/util.rpt
report_timing_summary -max_paths 4 -delay_type max -file $OUT/timing.rpt
puts "LUT_QUICK_DONE"
