# =====================================================================
# Out-of-context synth → place → route of ven_l2 ALONE (no core/SoC), to measure the
# L2's standalone Fmax + area on the KV260 part. OOC = the module is compiled in
# isolation (its u_*/d_* ports become OOC pins, no I/O buffers), so the numbers are the
# block's own logic/memory cost, not the whole SoC.
#
# Fmax is backed out from the worst setup slack at the (deliberately aggressive) target
# period:  Fmax = 1 / (PERIOD - WNS).  Over-constraining makes the tool push the timing
# so the back-calc is a tight estimate; pass a different period as the first tclarg to
# sweep (e.g. -tclargs 4.0).
#
# Run:  vivado -mode batch -source fpga/scripts/synth_l2_ooc.tcl -notrace [-tclargs <ns>]
# =====================================================================
set ROOT [pwd]
if {![file exists $ROOT/rtl/northbridge/ven_l2.sv]} {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set RTL  $ROOT/rtl
set OUT  $ROOT/fpga/build/l2_ooc
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
set PERIOD 2.5
if {$argc > 0} { set PERIOD [lindex $argv 0] }
puts "L2_OOC: PART=$PART  target period=${PERIOD} ns  ([format %.1f [expr 1000.0/$PERIOD]] MHz)"

create_project -in_memory -part $PART l2_ooc
read_verilog -sv $RTL/northbridge/ven_l2.sv

set xdc $OUT/l2.xdc
set fh [open $xdc w]
puts $fh "create_clock -period $PERIOD -name clk \[get_ports clk\]"
close $fh
read_xdc $xdc

# SYNTHESIS define drops the sim-only `ifndef SYNTHESIS` blocks (SVA + $fatal guards).
synth_design -top ven_l2 -part $PART -mode out_of_context -verilog_define SYNTHESIS
report_utilization -file $OUT/util_synth.rpt
puts "L2_OOC: synth done"

opt_design
place_design
phys_opt_design
route_design
puts "L2_OOC: place+route done"

report_utilization        -file $OUT/util_routed.rpt
report_timing_summary -max_paths 20 -delay_type max -file $OUT/timing_routed.rpt

# ---- Fmax from the worst setup path ----------------------------------------
set wns 0.0
set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
if {[llength $paths] > 0} { set wns [get_property SLACK [lindex $paths 0]] }
set fmax [expr 1000.0/($PERIOD - $wns)]

# ---- area (reliable primitive counts) --------------------------------------
proc ncells {filt} { return [llength [get_cells -hier -filter $filt]] }
set n_uram [ncells {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]
set n_rb36 [ncells {REF_NAME =~ RAMB36*}]
set n_rb18 [ncells {REF_NAME =~ RAMB18*}]
set n_dsp  [ncells {PRIMITIVE_TYPE =~ DSP.*}]
set n_lut "?"; catch { set n_lut [ncells {PRIMITIVE_GROUP == LUT}] }
set n_ff  "?"; catch { set n_ff  [ncells {PRIMITIVE_GROUP == FLOP_LATCH}] }
set n_carry "?"; catch { set n_carry [ncells {PRIMITIVE_TYPE =~ CARRY.*}] }

puts "============================================================"
puts "L2_OOC_RESULT  period=${PERIOD}ns  WNS=${wns}ns  Fmax=[format %.1f $fmax] MHz"
puts "L2_OOC_AREA  URAM288=$n_uram  RAMB36=$n_rb36  RAMB18=$n_rb18  LUT=$n_lut  FF=$n_ff  CARRY=$n_carry  DSP=$n_dsp"
puts "============================================================"
puts "L2_OOC_DONE"
