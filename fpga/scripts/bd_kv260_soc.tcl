# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# fpga/scripts/bd_kv260_soc.tcl — the FULL-SYSTEM KV260 SoC block design (F2). Extends
# bd_l1axi.tcl: the whole Ventium core (ventium_kv260_top = ventium_top + ven_soc_axil)
# on the PS8, with TWO seams to the PS:
#   * AXI4 master m_axi  -> SmartConnect (32->128) -> S_AXI_HPC0_FPD  (DDR carveout, coherent)
#   * AXI4-Lite s_axil   <- SmartConnect <- M_AXI_HPM0_FPD            (PS control + IO bridge)
#   * irq_out            -> ps8 pl_ps_irq0[0]                          (IO/syscall pending)
# Single pl_clk0 to everything (CDC_BYPASS). Two pass/fail bars (as bd_l1axi.tcl):
#   BAR-1  validate_bd_design -> 0 errors / 0 critical warnings
#   BAR-2  synth_design       -> the whole core + slave synthesize on xck26
# (On-wire AXI + the IO-bridge handshake are certified separately by the Verilator gates:
#  run-l1axi-*.sh, run-soc-axil-gate.sh.)
#
# Run (vivado is NOT on PATH):
#   /tools/Xilinx/2025.2/Vivado/bin/vivado -mode batch -source fpga/scripts/bd_kv260_soc.tcl
# Artifacts land under fpga/build/kv260_soc/.

set ROOT      [file normalize [file dirname [info script]]/../..]
set OUTDIR    $ROOT/fpga/build/kv260_soc
set PART      xck26-sfvc784-2LV-c
set BOARDPART xilinx.com:kv260_som:part0:1.4
set CARVEOUT_BASE 0x0000000040000000
set CARVEOUT_SIZE 0x0000000010000000
set HPM0_BASE     0x00000000A0000000
set HPM0_SIZE     0x0000000000010000
# env overrides: KV260_PL_FREQ (pl_clk0 MHz; the core is ~35 MHz routing-bound at this
# util, so a first WORKING bitstream uses a conservative clock), KV260_DO_IMPL (1 =
# place+route+bitstream after synth).
set PL_FREQ [expr {[info exists ::env(KV260_PL_FREQ)] ? $::env(KV260_PL_FREQ) : 100}]
set DO_IMPL [expr {[info exists ::env(KV260_DO_IMPL)] ? $::env(KV260_DO_IMPL) : 0}]

file mkdir $OUTDIR
create_project -force ventium_kv260 $OUTDIR/proj -part $PART
catch { set_property board_part $BOARDPART [current_project] }

# ---- sources: the WHOLE core (packages first), L1/AXI, the SoC slave + wrappers ----
set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    ventium_top.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/uopcache.sv mem/tlb.sv
    bus/biu_p5.sv bus/biu.sv
    mem/ven_l1d.sv mem/ven_axi_master.sv mem/ventium_l1_axi.sv
    soc/ven_soc_axil.sv soc/ventium_kv260_core.sv
}
foreach f $svfiles { add_files -norecurse $ROOT/rtl/$f }
add_files -norecurse $ROOT/rtl/soc/ventium_kv260_top.v   ;# Verilog BD-reference TOP
set_property file_type SystemVerilog [get_files *.sv]
# core.sv `include "core_*.svh"s its giant case-arm fragments — add them as HEADER
# files (else the BD project treats each as a standalone RTL module and errors) and
# point +incdir at rtl/core so the includes resolve.
add_files -norecurse [glob $ROOT/rtl/core/*.svh]
set_property file_type {Verilog Header} [get_files *.svh]
set_property include_dirs [list $ROOT/rtl/core] [current_fileset]
# SYNTHESIS+VTM_NO_DPI drop sim-only $fatal/SVA/DPI; the FPGA iterative engines + fit
# enablers match the production synth (apr_run.tcl); +VEN_L1_AXI +VEN_KV260_SOC select
# the mode-2 AXI master + the SoC control/IO seam.
set_property verilog_define {SYNTHESIS VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER \
    VEN_FP_PIPE VEN_BTB_PIPE VEN_IC_NARROWB VEN_L1_AXI VEN_KV260_SOC} [current_fileset]
update_compile_order -fileset sources_1

# ---- block design --------------------------------------------------------------
create_bd_design design_kv260

set psvlnv [lindex [lsort [get_ipdefs xilinx.com:ip:zynq_ultra_ps_e:*]] end]
create_bd_cell -type ip -vlnv $psvlnv ps8
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset 1} [get_bd_cells ps8]

# HPC0 (SAXIGP0, 128b, AFI coherent) for DDR + HPM0 (MAXIGP0, 32b) for control +
# pl_ps_irq0 for the IO/syscall interrupt; one PL clock @ 100 MHz. Disable the unused
# HPM1/2 master clocks (a dangling HPM*_aclk fails validate).
set_property -dict [list \
    CONFIG.PSU__USE__S_AXI_GP0 {1} \
    CONFIG.PSU__SAXIGP0__DATA_WIDTH {128} \
    CONFIG.PSU__AFI0_COHERENCY {1} \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__IRQ0 {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $PL_FREQ ] [get_bd_cells ps8]

# ventium_kv260_top (the Verilog wrapper) as a Module Reference. Its X_INTERFACE attrs
# must infer the master `m_axi`, the slave `s_axil`, and the interrupt `irq_out`.
create_bd_cell -type module -reference ventium_kv260_top u_kv260
foreach bif {m_axi s_axil} {
  if {[llength [get_bd_intf_pins u_kv260/$bif]] == 0} {
    error "FAIL: ventium_kv260_top $bif interface not inferred — check X_INTERFACE_INFO"
  }
}

# ---- AXI: m_axi -> SmartConnect -> S_AXI_HPC0_FPD (DDR) -------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_mem
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells sc_mem]
connect_bd_intf_net [get_bd_intf_pins u_kv260/m_axi]  [get_bd_intf_pins sc_mem/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_mem/M00_AXI] [get_bd_intf_pins ps8/S_AXI_HPC0_FPD]

# ---- AXI-Lite: M_AXI_HPM0_FPD -> SmartConnect -> s_axil (control) --------------
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_ctrl
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells sc_ctrl]
connect_bd_intf_net [get_bd_intf_pins ps8/M_AXI_HPM0_FPD] [get_bd_intf_pins sc_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_ctrl/M00_AXI]    [get_bd_intf_pins u_kv260/s_axil]

# ---- interrupt: irq_out -> ps8 pl_ps_irq0 -------------------------------------
connect_bd_net [get_bd_pins u_kv260/irq_out] [get_bd_pins ps8/pl_ps_irq0]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst0

# ---- clocks / resets: one PL clock to everything (CDC_BYPASS) ------------------
connect_bd_net [get_bd_pins ps8/pl_clk0] \
    [get_bd_pins u_kv260/clk] \
    [get_bd_pins sc_mem/aclk] [get_bd_pins sc_ctrl/aclk] \
    [get_bd_pins ps8/saxihpc0_fpd_aclk] [get_bd_pins ps8/maxihpm0_fpd_aclk] \
    [get_bd_pins rst0/slowest_sync_clk]
connect_bd_net [get_bd_pins ps8/pl_resetn0] [get_bd_pins rst0/ext_reset_in]
connect_bd_net [get_bd_pins rst0/peripheral_aresetn] \
    [get_bd_pins u_kv260/aresetn] \
    [get_bd_pins sc_mem/aresetn] [get_bd_pins sc_ctrl/aresetn]

# ---- address map: m_axi -> the DDR carveout; s_axil -> the HPM0 aperture --------
assign_bd_address
catch {
    set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces u_kv260/m_axi]]
    set ddr [get_bd_addr_segs ps8/SAXIGP0/HPC0_DDR_LOW]
    if {$seg ne "" && $ddr ne ""} {
        delete_bd_objs [get_bd_addr_segs $seg]
        create_bd_addr_seg -range $CARVEOUT_SIZE -offset $CARVEOUT_BASE \
            [get_bd_addr_spaces u_kv260/m_axi] $ddr SEG_carveout
    }
}
catch {
    set cseg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps8/Data] -filter {NAME =~ *s_axil*}]
    if {$cseg ne ""} {
        delete_bd_objs $cseg
        create_bd_addr_seg -range $HPM0_SIZE -offset $HPM0_BASE \
            [get_bd_addr_spaces ps8/Data] [get_bd_addr_segs u_kv260/s_axil/*] SEG_ctrl
    }
}

# ---- BAR-1: validate ----------------------------------------------------------
puts "=== BAR-1: validate_bd_design ==="
validate_bd_design
save_bd_design

# ---- BAR-2: synthesize --------------------------------------------------------
make_wrapper -files [get_files design_kv260.bd] -top
add_files -norecurse $OUTDIR/proj/ventium_kv260.gen/sources_1/bd/design_kv260/hdl/design_kv260_wrapper.v
set_property top design_kv260_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "=== BAR-2: synth_design ==="
launch_runs synth_1 -jobs 8
wait_on_run synth_1
open_run synth_1 -name synth_1
report_drc            -file $OUTDIR/drc.rpt
report_utilization    -file $OUTDIR/util.rpt
report_timing_summary -file $OUTDIR/timing.rpt

set st [get_property STATUS [get_runs synth_1]]
set pr [get_property PROGRESS [get_runs synth_1]]
puts "=== synth_1 status=$st progress=$pr ==="
if {$pr ne "100%"} { error "FAIL: synth_design did not complete (progress=$pr)" }
puts "=== BD-KV260-SOC-OK: validate + full-core synth clean (see $OUTDIR/{drc,util,timing}.rpt) ==="

# ---- BAR-3 (optional): place + route + bitstream -------------------------------
if {$DO_IMPL} {
    puts "=== BAR-3: impl (place+route+bitstream) @ pl_clk0 = $PL_FREQ MHz ==="
    reset_run impl_1
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
    set ist [get_property STATUS   [get_runs impl_1]]
    set ipr [get_property PROGRESS [get_runs impl_1]]
    set wns [get_property STATS.WNS [get_runs impl_1]]
    open_run impl_1
    report_timing_summary -file $OUTDIR/impl_timing.rpt
    report_utilization    -file $OUTDIR/impl_util.rpt
    report_drc            -file $OUTDIR/impl_drc.rpt
    set bit $OUTDIR/proj/ventium_kv260.runs/impl_1/design_kv260_wrapper.bit
    puts "=== impl_1 status=$ist progress=$ipr WNS=$wns ns @ $PL_FREQ MHz ==="
    if {[file exists $bit]} {
        file copy -force $bit $OUTDIR/ventium_kv260.bit
        if {$wns >= 0} {
            puts "=== BIT-KV260-OK: bitstream written + TIMING MET (WNS=$wns ns @ $PL_FREQ MHz) -> $OUTDIR/ventium_kv260.bit ==="
        } else {
            puts "=== BIT-KV260-TIMING-FAIL: bitstream written but WNS=$wns ns < 0 @ $PL_FREQ MHz (lower KV260_PL_FREQ) ==="
        }
    } else {
        puts "=== BIT-KV260-FAIL: no bitstream (impl progress=$ipr — likely unroutable congestion) ==="
    }
}
