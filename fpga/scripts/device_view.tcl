# =====================================================================
# Device-view generator: synth + place the BEST config, then (a) dump every
# placed leaf cell's site LOC + its top-hierarchy module to a CSV (for the
# matplotlib colored device view), and (b) drive the Vivado GUI device window
# with per-module highlight colors + capture it via ImageMagick (the authentic
# Vivado device view). Also reports the headline util/timing numbers.
#
# Run:  vivado -mode batch -source fpga/scripts/device_view.tcl -notrace
# (DISPLAY must be set for the GUI capture; the CSV dump works headless.)
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/device_view
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART dv

set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/tlb.sv
}
foreach f $svfiles { read_verilog -sv $RTL/$f }
set xdc $OUT/clk.xdc
set fh [open $xdc w]; puts $fh "create_clock -period 15.000 -name clk \[get_ports clk\]"; close $fh
read_xdc $xdc

# BEST config: all iter engines + FP pipeline + BTB pipeline (+VEN_BTB_PIPE is the
# removable option). Compare-consolidation is in the default RTL.
synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE} \
    -flatten_hierarchy rebuilt
opt_design
place_design -directive ExtraTimingOpt
phys_opt_design
report_utilization -file $OUT/util.rpt
report_timing_summary -max_paths 4 -delay_type max -file $OUT/timing.rpt
write_checkpoint -force $OUT/core_best_placed.dcp
puts "DEVICE_VIEW_PLACED_DONE"

# ---- (a) CSV dump: module,x,y for each placed leaf cell -------------------
set fh [open $OUT/cells_loc.csv w]
puts $fh "module,x,y"
set n 0
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE==1}] {
    set loc [get_property LOC $c]
    if {$loc eq ""} continue
    if {![regexp {[A-Z_]+X([0-9]+)Y([0-9]+)} $loc -> x y]} continue
    # top-hierarchy module = first path component (the instance), else "core_spine"
    set nm [get_property NAME $c]
    if {[regexp {^(u_[A-Za-z0-9_]+)/} $nm -> inst]} { set mod $inst } else { set mod "core_spine" }
    puts $fh "$mod,$x,$y"
    incr n
}
close $fh
puts "DEVICE_VIEW_CSV_DONE cells=$n"

# (the authentic Vivado GUI capture is attempted separately on core_best_placed.dcp
# via device_view_gui.tcl — kept out of this batch run so a GUI hang can't block
# the reliable CSV/DCP deliverable.)
puts "DEVICE_VIEW_DONE"
