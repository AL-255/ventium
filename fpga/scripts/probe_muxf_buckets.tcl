# =====================================================================
# P0-11c REFINED MUXF buckets — split the 5,836 core-inline F7 into the
# slow-path DECODER vs fast slot-read vs ALU vs FP vs the rest, by output-net
# name pattern. Decides whether the slow-path decoder is a big enough single
# target to justify the very-large sequentialization, or whether the band MUXF
# is too diffuse for any one front-end lever (=> floorplan/in-context is the cure).
#
# Run:  vivado -mode batch -source fpga/scripts/probe_muxf_buckets.tcl -notrace
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/core/core.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/muxf_buckets
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART probe_muxf_buckets

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

# Only the TOP-level (core-inline) MUXF7 cells — bucket by output-net name.
# Use the cell name itself (Vivado derives MUXF names from the driven net).
set f7s [get_cells -filter {REF_NAME == MUXF7}]
array set b {slowdec 0 ibuf 0 fastslot 0 alu 0 fp 0 btbglue 0 other 0}
foreach c $f7s {
    set n [string tolower $c]
    if {[regexp {ibuf} $n]} { incr b(ibuf) ; continue }
    if {[regexp {(d_|pfx|modrm|m_idx|disp|sib|two_byte|mrm|decode_s|amode|mfl)} $n]} { incr b(slowdec) ; continue }
    if {[regexp {(uc_|u_d|v_d|slot|bslot|uop)} $n]} { incr b(fastslot) ; continue }
    if {[regexp {(alu|shift|flags|adder|carry)} $n]} { incr b(alu) ; continue }
    if {[regexp {(fp|fpr|fpp|fx_|st0|sti|fstat|fctrl)} $n]} { incr b(fp) ; continue }
    if {[regexp {(btb|pred|target|rel)} $n]} { incr b(btbglue) ; continue }
    incr b(other)
}
set fh2 [open $OUT/core_inline_buckets.txt w]
puts $fh2 "core-inline MUXF7 total = [llength $f7s]"
foreach k {ibuf slowdec fastslot alu fp btbglue other} {
    puts $fh2 [format "%-12s %6d" $k $b($k)]
}
close $fh2
puts "BUCKETS: ibuf=$b(ibuf) slowdec=$b(slowdec) fastslot=$b(fastslot) alu=$b(alu) fp=$b(fp) btbglue=$b(btbglue) other=$b(other) total=[llength $f7s]"
puts "MUXF_BUCKETS_DONE"
