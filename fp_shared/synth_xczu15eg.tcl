# Standalone out-of-context FP synthesis for the current RK-XCZU15EG-F target.
# Usage: vivado -mode batch -source synth_xczu15eg.tcl -tclargs old|shared

set part xczu15eg-ffvb1156-2-i
set scratch [file normalize [file dirname [info script]]]
if {[info exists ::env(VENTIUM_REPO)]} {
  set repo [file normalize $::env(VENTIUM_REPO)]
} else {
  set repo [file dirname $scratch]
}
# Keep the standalone audit bounded on this 32 GiB host.  Runtime is secondary
# to obtaining two comparable reports without competing with unrelated work.
set_param general.maxThreads 1

if {$argc != 1 || [lsearch -exact {old shared} [lindex $argv 0]] < 0} {
  error "expected exactly one variant: old or shared"
}
set variant [lindex $argv 0]
set outdir $scratch/ooc_xczu15eg_$variant
if {[file exists $outdir]} {
  file delete -force $outdir
}
file mkdir $outdir

set common [list \
  $repo/rtl/core/ventium_decode_pkg.sv \
  $repo/rtl/fpu/fpu_x87_pkg.sv \
  $repo/rtl/core/ventium_x87_pkg.sv \
  $repo/rtl/fpu/ven_bcd.sv \
  $repo/rtl/fpu/ven_bcd_to_fp.sv \
  $repo/rtl/fpu/fpu_estdiv.sv]

if {$variant eq "old"} {
  set top ven_fp_old_ooc
  set sources [concat $common [list \
    $repo/rtl/fpu/fpu_top.sv \
    $repo/rtl/fpu/fpu_fx_ppl.sv \
    $repo/rtl/fpu/fpu_srt_div.sv \
    $repo/rtl/fpu/fpu_fsincos.sv \
    $repo/rtl/fpu/fpu_f2xm1.sv \
    $repo/rtl/fpu/fpu_fyl2x.sv \
    $repo/rtl/fpu/fpu_fpatan.sv \
    $scratch/ven_fp_misc.sv \
    $scratch/ven_fp_old_ooc.sv]]
} else {
  set top ven_fp_top
  set sources [concat $common [list \
    $scratch/fpu_srt_div.sv \
    $scratch/ven_fp_state.sv \
    $scratch/ven_fp_alu.sv \
    $scratch/ven_fp_misc.sv \
    $scratch/ven_fp_widemul.sv \
    $scratch/ven_fp_estdiv.sv \
    $scratch/ven_fp_trans.sv \
    $scratch/ven_fp_top.sv]]
}

create_project -in_memory -part $part
add_files -norecurse $sources
set_property include_dirs [list $repo/rtl/fpu] [current_fileset]
set_property verilog_define {SYNTHESIS VEN_FPREM} [current_fileset]
set_property top $top [current_fileset]

# This is deliberately not the board project flow: no BD, PS, IP generation,
# implementation, bitstream, or shared build directory is opened.
synth_design -mode out_of_context -top $top -part $part \
  -flatten_hierarchy none -directive AreaOptimized_medium
create_clock -name fp_clk -period 320.000 [get_ports clk]

report_utilization -file $outdir/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 4 \
  -file $outdir/utilization_hier.rpt
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
  -file $outdir/timing_summary.rpt
report_high_fanout_nets -timing -max_nets 50 \
  -file $outdir/high_fanout.rpt
write_checkpoint -force $outdir/${top}_synth.dcp

puts "VEN-FP-OOC-[string toupper $variant]-OK"
