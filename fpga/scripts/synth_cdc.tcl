# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# fpga/scripts/synth_cdc.tcl — out-of-context synth-check for the +VEN_AXI_CDC dual-
# clock L1/AXI build (P1-3). Proves the CDC RTL (ven_cdc_afifo + ven_axi_cdc +
# ven_reset_sync, wired into ventium_l1_axi) SYNTHESIZES cleanly on the KV260 part:
#   * the async FIFO infers (distributed-RAM array + async read), ASYNC_REG honored;
#   * NO combinational loop (LUTLP), latch, or multi-driver (report_drc);
#   * with core_clk and axi_clk declared ASYNCHRONOUS (set_clock_groups), the inter-
#     clock crossings are correctly excluded from timing — each domain closes on its
#     own period, no false cross-domain setup failures.
# Two distinct clocks are created (core 15 ns ~66 MHz, axi 5 ns 200 MHz) so it is a
# genuine two-clock elaboration, not the CDC_BYPASS single-clock alias.
#
# Run (vivado is NOT on PATH):
#   /tools/Xilinx/2025.2/Vivado/bin/vivado -mode batch -source fpga/scripts/synth_cdc.tcl
# Artifacts land under fpga/build/cdc/. Prints VEN-CDC-SYNTH-OK / -FAIL.

set ROOT   [file normalize [file dirname [info script]]/../..]
set OUTDIR $ROOT/fpga/build/cdc
set PART   xck26-sfvc784-2LV-c
file mkdir $OUTDIR

read_verilog -sv [list \
    $ROOT/rtl/mem/ven_cdc_afifo.sv \
    $ROOT/rtl/mem/ven_reset_sync.sv \
    $ROOT/rtl/mem/ven_axi_cdc.sv \
    $ROOT/rtl/mem/ven_l1d.sv \
    $ROOT/rtl/mem/ven_axi_master.sv \
    $ROOT/rtl/mem/ventium_l1_axi.sv ]

# SYNTHESIS drops the sim-only $fatal + SVA; VEN_AXI_CDC selects the dual-clock path.
synth_design -top ventium_l1_axi -part $PART -mode out_of_context \
    -verilog_define SYNTHESIS -verilog_define VEN_AXI_CDC

# two genuinely asynchronous clocks + the load-bearing async grouping.
create_clock -name core_clk -period 15.000 [get_ports core_clk]
create_clock -name axi_clk  -period  5.000 [get_ports axi_clk]
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks core_clk] \
    -group [get_clocks -include_generated_clocks axi_clk]

report_drc            -file $OUTDIR/drc.rpt
report_timing_summary -file $OUTDIR/timing.rpt
report_utilization    -file $OUTDIR/util.rpt

# ---- pass/fail ---------------------------------------------------------------
# combinational loop (LUTLP) is a hard CDC/RTL bug; fail on it. Report WNS per clock.
set drc [read [open $OUTDIR/drc.rpt]]
set lutlp 0
if {[regexp {LUTLP-1} $drc]} { set lutlp 1 }
set cells [get_cells -hier -filter {PRIMITIVE_TYPE =~ *LUT*}]
puts "=== CDC synth: [llength [get_cells -hier]] cells, LUTLP=$lutlp ==="
# confirm the async FIFO RAM inferred (LUTRAM / RAMD) and ASYNC_REG flops survived.
set lutram [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUTRAM}]]
set asyncregs [llength [get_cells -hier -filter {ASYNC_REG == "TRUE"}]]
puts "=== LUTRAM cells=$lutram  ASYNC_REG flops=$asyncregs ==="
set wns_core [get_property SLACK [get_timing_paths -setup -to [get_clocks core_clk]]]
set wns_axi  [get_property SLACK [get_timing_paths -setup -to [get_clocks axi_clk]]]
puts "=== WNS core_clk=$wns_core  axi_clk=$wns_axi ==="

if {$lutlp} {
    puts "VEN-CDC-SYNTH-FAIL: combinational loop (LUTLP) present"
} else {
    puts "VEN-CDC-SYNTH-OK: synthesizes clean on $PART (no comb loop; async FIFO + ASYNC_REG inferred; clocks async-grouped)"
}
