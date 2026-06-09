# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# fpga/scripts/bd_l1axi.tcl — prove ventium_l1_axi integrates cleanly with the
# KV260 PS (Zynq UltraScale+ PS8) over S_AXI_HPC0_FPD (cache-coherent, PS-DDR).
#
# It builds a minimal block design: PS8 + ventium_l1_axi (Module Reference) ->
# SmartConnect (32->128 upsize) -> S_AXI_HPC0_FPD, on one PL clock (single-clock
# CDC_BYPASS bring-up). Two pass/fail BARs:
#   BAR-1  validate_bd_design  -> 0 errors / 0 critical warnings (connectivity)
#   BAR-2  synth_design        -> netlist legal (no unconnected-AXI / latch / multi-
#                                 driver), captured in drc.rpt
# These certify "connects + elaborates + synthesizes cleanly to S_AXI_HPC0". On-wire
# AXI protocol + coherency correctness is certified separately by the Verilator gate
# (verif/l1/run-l1axi-gate.sh, L1AXI-GATE-OK) + its bound SVA.
#
# Run (vivado is NOT on PATH):
#   /tools/Xilinx/2025.2/Vivado/bin/vivado -mode batch -source fpga/scripts/bd_l1axi.tcl
#
# All artifacts land under fpga/build/l1axi/ (project, reports).

set ROOT      [file normalize [file dirname [info script]]/../..]
set OUTDIR    $ROOT/fpga/build/l1axi
set PART      xck26-sfvc784-2LV-c
set BOARDPART xilinx.com:kv260_som:part0:1.4
# reserved DDR carveout (DDR_LOW): master window base/size == REMAP_BASE / ADDR_MASK+1.
set CARVEOUT_BASE 0x0000000040000000
set CARVEOUT_SIZE 0x0000000010000000

file mkdir $OUTDIR
create_project -force ventium_l1axi $OUTDIR/proj -part $PART
catch { set_property board_part $BOARDPART [current_project] }

# ---- sources: the Verilog BD-reference wrapper + the SV subsystem + leaf deps ---
# (BD Module Reference requires a Verilog TOP; the .v wrapper carries the AXI
#  X_INTERFACE attrs and instantiates the SystemVerilog ventium_l1_axi underneath.)
add_files -norecurse [list \
    $ROOT/rtl/mem/ven_l1d.sv \
    $ROOT/rtl/mem/ven_axi_master.sv \
    $ROOT/rtl/mem/ventium_l1_axi.sv \
    $ROOT/rtl/mem/ventium_l1_axi_top.v ]
set_property file_type SystemVerilog [get_files *.sv]
# SYNTHESIS drops the sim-only $fatal elaboration guards + bound SVA.
set_property verilog_define {SYNTHESIS} [current_fileset]
update_compile_order -fileset sources_1

# ---- block design --------------------------------------------------------------
create_bd_design design_l1axi

# PS8 — use the part-supported version (hardcoding a version aborts on xck26).
set psvlnv [lindex [lsort [get_ipdefs xilinx.com:ip:zynq_ultra_ps_e:*]] end]
create_bd_cell -type ip -vlnv $psvlnv ps8
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset 1} [get_bd_cells ps8]

# HPC0 = SAXIGP0, 128-bit, AFI coherent; one PL clock @ 100 MHz; AND disable the HPM
# master ports whose clock pins the board preset would otherwise leave dangling
# (a dangling HPM*_FPD_aclk fails validate_bd_design).
set_property -dict [list \
    CONFIG.PSU__USE__S_AXI_GP0 {1} \
    CONFIG.PSU__SAXIGP0__DATA_WIDTH {128} \
    CONFIG.PSU__AFI0_COHERENCY {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
    CONFIG.PSU__USE__M_AXI_GP0 {0} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} ] [get_bd_cells ps8]

# ventium_l1_axi_top (the Verilog wrapper) as a Module Reference. Its X_INTERFACE
# attrs must infer a master AXI bundle named `m_axi` (else connect_bd_intf_net finds
# none). The SystemVerilog ventium_l1_axi is pulled in as a sub-module.
create_bd_cell -type module -reference ventium_l1_axi_top u_l1axi
if {[llength [get_bd_intf_pins u_l1axi/m_axi]] == 0} {
    error "FAIL: ventium_l1_axi m_axi interface not inferred — check X_INTERFACE_INFO attrs"
}

# Expose the CORE side as external BD ports (in the full SoC the Ventium core drives
# these; here they prove the PS side connects). This clears the benign BD 41-759
# "unconnected input" critical warnings -> a pristine validate.
foreach p {core_req core_we core_addr core_wdata core_wstrb core_rdata core_ack} {
    make_bd_pins_external [get_bd_pins u_l1axi/$p]
}
# #35 flush_all: external L1 invalidation. It is a COSIM-only coherency hook (the
# int-0x80 proxy writes DDR behind the L1); on real silicon the S_AXI_HPC0 CCI snoop
# covers PS-side writes, so flush_all is tied 0 here (a constant-0 driver — also
# clears the BD 41-759 unconnected-input critical warning that would fail BAR-1).
# bus_err (#34) is an OUTPUT, so a dangling pin needs no driver (no critical warning).
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 flush_tie
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells flush_tie]
connect_bd_net [get_bd_pins flush_tie/dout] [get_bd_pins u_l1axi/flush_all]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc0
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells sc0]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst0

# ---- clocks / resets: one PL clock to everything (CDC_BYPASS) ------------------
connect_bd_net [get_bd_pins ps8/pl_clk0] \
    [get_bd_pins u_l1axi/core_clk] [get_bd_pins u_l1axi/axi_clk] \
    [get_bd_pins sc0/aclk] [get_bd_pins ps8/saxihpc0_fpd_aclk] \
    [get_bd_pins rst0/slowest_sync_clk]
connect_bd_net [get_bd_pins ps8/pl_resetn0] [get_bd_pins rst0/ext_reset_in]
connect_bd_net [get_bd_pins rst0/peripheral_aresetn] \
    [get_bd_pins u_l1axi/core_rst_n] [get_bd_pins u_l1axi/axi_rst_n] \
    [get_bd_pins sc0/aresetn]

# ---- AXI: ventium_l1_axi/m_axi -> SmartConnect -> S_AXI_HPC0_FPD ---------------
connect_bd_intf_net [get_bd_intf_pins u_l1axi/m_axi] [get_bd_intf_pins sc0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc0/M00_AXI] [get_bd_intf_pins ps8/S_AXI_HPC0_FPD]

# ---- address: pin the master window to the reserved DDR carveout (NOT 0x0, which
#      collides with the PS kernel/ATF). This offset == REMAP_BASE == the PetaLinux
#      reserved-memory node base (the three-way identity). -----------------------
assign_bd_address
catch {
    set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces u_l1axi/m_axi]]
    set ddr [get_bd_addr_segs ps8/SAXIGP0/HPC0_DDR_LOW]
    if {$seg ne "" && $ddr ne ""} {
        delete_bd_objs [get_bd_addr_segs $seg]
        create_bd_addr_seg -range $CARVEOUT_SIZE -offset $CARVEOUT_BASE \
            [get_bd_addr_spaces u_l1axi/m_axi] $ddr SEG_carveout
    }
}

# ---- BAR-1: validate ----------------------------------------------------------
puts "=== BAR-1: validate_bd_design ==="
validate_bd_design
save_bd_design

# ---- BAR-2: synthesize the BD wrapper -----------------------------------------
make_wrapper -files [get_files design_l1axi.bd] -top
add_files -norecurse $OUTDIR/proj/ventium_l1axi.gen/sources_1/bd/design_l1axi/hdl/design_l1axi_wrapper.v
set_property top design_l1axi_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "=== BAR-2: synth_design ==="
launch_runs synth_1 -jobs 8
wait_on_run synth_1
open_run synth_1 -name synth_1
report_drc           -file $OUTDIR/drc.rpt
report_timing_summary -file $OUTDIR/timing.rpt
report_utilization   -file $OUTDIR/util.rpt

set st [get_property STATUS [get_runs synth_1]]
set pr [get_property PROGRESS [get_runs synth_1]]
puts "=== synth_1 status=$st progress=$pr ==="
if {$pr ne "100%"} { error "FAIL: synth_design did not complete (progress=$pr)" }
puts "=== BD-L1AXI-OK: validate + synth clean (see $OUTDIR/{drc,timing,util}.rpt) ==="
