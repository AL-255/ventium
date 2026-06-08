# =====================================================================
# P0-11b MUXF ATTRIBUTION probe (+VEN_IC_BRAM +VEN_UOPCACHE), hierarchy KEPT.
#
# After the µop-cache removed the fast-path byte gather (−22/−33% MUXF) the OOC
# placed congestion held at level-5. Finding: the gather was only ~25-33% of the
# band MUXF; the rest is elsewhere in the front-end. THIS probe localizes the
# remaining 11,291 F7 / 4,152 F8 by HIERARCHY (flatten_hierarchy none +
# report_utilization -hierarchical) so the next (very-large) lever attacks the
# real dominant contributor — slow-path ibuf decoder vs FP datapath vs issue mux.
#
# Run:  vivado -mode batch -source fpga/scripts/probe_muxf_attrib.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/muxf_attrib
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART probe_muxf_attrib

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

# flatten_hierarchy none KEEPS module boundaries so report_utilization
# -hierarchical attributes MUXF per instance (u_uopcache / u_fpu_state / etc.;
# the INLINE slow-path decoder + issue + fast slot-read stay under `core`).
synth_design -top core -part $PART -mode out_of_context -include_dirs $RTL/core \
    -verilog_define {VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_BRAM VEN_UOPCACHE} \
    -flatten_hierarchy none
report_utilization -hierarchical -hierarchical_depth 3 -file $OUT/util_hier.rpt

# also dump every MUXF7's parent-hierarchy tally, robust to report format.
set f7s [get_cells -hier -filter {REF_NAME == MUXF7}]
set f8s [get_cells -hier -filter {REF_NAME == MUXF8}]
array set f7tally {}
foreach c $f7s {
    set p [lindex [split $c /] end-1]
    # group by the SECOND-level instance (u_core child) when present.
    set parts [split $c /]
    if {[llength $parts] >= 2} { set key [lindex $parts end-1] } else { set key "(top)" }
    incr f7tally($key)
}
set fh2 [open $OUT/f7_by_parent.txt w]
puts $fh2 "MUXF7 total = [llength $f7s]   MUXF8 total = [llength $f8s]"
foreach k [lsort [array names f7tally]] { puts $fh2 [format "%-40s %6d" $k $f7tally($k)] }
close $fh2
puts "MUXF_ATTRIB_F7_TOTAL=[llength $f7s]"
puts "MUXF_ATTRIB_F8_TOTAL=[llength $f8s]"
puts "MUXF_ATTRIB_DONE"
