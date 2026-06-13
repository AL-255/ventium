# =====================================================================
# fpga/scripts/impl_kv260_soc.tcl — FULL-SoC IMPLEMENTATION → bitstream + .xsa.
#
# Extends bd_kv260_soc.tcl (validate + synth only) to the deployable artifacts:
#   synth_1 -> impl_1 (place + route + write_bitstream) -> write_hw_platform (.xsa).
#
# DELIBERATE config choices for the deployable board image (vs the validate script).
# NOTE: pl_clk0 = 50 MHz, NOT 60. A 60 MHz full-SoC close is not feasible on the small
# XCK26 (ZU5EV): the OOC core ceiling is 65.3 MHz, but the full SoC's extra L1/AXI + BD
# fabric leaves diffuse fill->eip routing congestion that no P&R/floorplan clears, so the
# routed Fmax tops out ~50 MHz (FE_PIPE). 50 MHz closes with positive margin; a larger
# part (ZU15EG) would clear 60+.
#   * CONFIG = uop-cache + half-cache + FP_PIPE2 (VEN_UOPCACHE + VEN_IC_BRAM +
#     VEN_CACHE_HALF + VEN_FP_PIPE2), NOT narrowb: narrowb hits the single-cycle
#     byte-window MUXF congestion wall and does NOT route on the small xck26; the
#     uop-cache deletes that decoder (routable), FP_PIPE2 splits the FADD-commit cone
#     (cycle-safe, make verify-fppipe2), and the BCD ÷100 step is already in ven_bcd.
#     This is the config that routes the OOC core at 65.3 MHz — ~5 MHz over the target.
#   * pl_clk0 = 50 MHz: the achievable in-context target (see the note above); the
#     +VEN_FE_PIPE build routes it with positive WNS.
#   * impl strategy Performance_NetDelay_high (the ExtraNetDelay placement that won
#     the OOC sweeps for this route-bound design).
#
# Artifacts: fpga/build/kv260_soc_impl/ventium_kv260.{bit,xsa} + timing/util/drc rpts.
# Run: /tools/Xilinx/2025.2/Vivado/bin/vivado -mode batch -source fpga/scripts/impl_kv260_soc.tcl
# =====================================================================
set ROOT      [file normalize [file dirname [info script]]/../..]
# FE_PIPE=1 adds +VEN_FE_PIPE (page-keyed micro-TLB) to break the eip/TLB fetch cone;
# OUTTAG gives it its own build dir so it doesn't clobber the baseline impl.
proc envor {n d} { if {[info exists ::env($n)] && $::env($n) ne ""} { return $::env($n) } else { return $d } }
set FEP       [envor FE_PIPE 0]
set OUTTAG    [envor OUTTAG ""]
set OUTDIR    $ROOT/fpga/build/kv260_soc_impl$OUTTAG
set PART      xck26-sfvc784-2LV-c
set BOARDPART xilinx.com:kv260_som:part0:1.4
set CARVEOUT_BASE 0x0000000040000000
set CARVEOUT_SIZE 0x0000000010000000
set HPM0_BASE     0x00000000A0000000
set HPM0_SIZE     0x0000000000010000
set PL0_MHZ       [envor PL0_MHZ 50]
set THREADS       [expr {[info exists ::env(THREADS)] ? $::env(THREADS) : 16}]
set_param general.maxThreads $THREADS

file mkdir $OUTDIR
create_project -force ventium_kv260_impl $OUTDIR/proj -part $PART
catch { set_property board_part $BOARDPART [current_project] }

set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    ventium_top.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    mem/dcache_timing.sv mem/icache.sv mem/uopcache.sv mem/tlb.sv
    bus/biu_p5.sv bus/biu.sv
    mem/ven_l1d.sv mem/ven_axi_master.sv mem/ventium_l1_axi.sv
    soc/ven_soc_axil.sv soc/ven_soc_dbg.sv soc/ventium_kv260_core.sv
}
foreach f $svfiles { add_files -norecurse $ROOT/rtl/$f }
add_files -norecurse $ROOT/rtl/soc/ventium_kv260_top.v
set_property file_type SystemVerilog [get_files *.sv]
add_files -norecurse [glob $ROOT/rtl/core/*.svh]
set_property file_type {Verilog Header} [get_files *.svh]
set_property include_dirs [list $ROOT/rtl/core] [current_fileset]
# uop-cache + half-cache + 2-stage FP commit (routable, 65.3 MHz OOC) + SoC seams.
set DEFS {SYNTHESIS VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER \
    VEN_FP_PIPE VEN_FP_PIPE2 VEN_IC_BRAM VEN_CACHE_HALF \
    VEN_L1_AXI VEN_KV260_SOC}
# Fetch-path feature defines are env-controllable (default ON, matching linux_40)
# so a CALL/RET / fetch-redirect synth bug can be bisected by dropping one at a time:
#   BTB_PIPE=0 (pipelined BTB), UOPCACHE=0 (micro-op cache), FE_PIPE=1 (fetch pipe).
if {[envor BTB_PIPE 1]} { lappend DEFS VEN_BTB_PIPE }
if {[envor UOPCACHE 1]} { lappend DEFS VEN_UOPCACHE }
if {$FEP} { lappend DEFS VEN_FE_PIPE }
# DBG_CORE=1 builds a DEBUG BITSTREAM: the on-die debug/trace unit (committed
# state + PC ring + freeze detector + perf counters + single-step/breakpoint via
# the ven_soc_axil 0x80+ window). Costs a little BRAM + routing, so it is OFF for
# the timing-critical production close; turn on for a forensic/bring-up bitstream.
if {[envor DBG_CORE 0]} { lappend DEFS VEN_DBG_CORE }
set_property verilog_define $DEFS [current_fileset]
update_compile_order -fileset sources_1

# ---- block design (identical topology to bd_kv260_soc.tcl) ----------------------
create_bd_design design_kv260
set psvlnv [lindex [lsort [get_ipdefs xilinx.com:ip:zynq_ultra_ps_e:*]] end]
create_bd_cell -type ip -vlnv $psvlnv ps8
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset 1} [get_bd_cells ps8]
set_property -dict [list \
    CONFIG.PSU__USE__S_AXI_GP0 {1} \
    CONFIG.PSU__SAXIGP0__DATA_WIDTH {128} \
    CONFIG.PSU__AFI0_COHERENCY {1} \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__IRQ0 {1} \
    CONFIG.PSU__UART1__PERIPHERAL__ENABLE {1} \
    CONFIG.PSU__UART1__PERIPHERAL__IO {MIO 36 .. 37} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $PL0_MHZ ] [get_bd_cells ps8]

create_bd_cell -type module -reference ventium_kv260_top u_kv260
foreach bif {m_axi s_axil} {
  if {[llength [get_bd_intf_pins u_kv260/$bif]] == 0} {
    error "FAIL: ventium_kv260_top $bif interface not inferred — check X_INTERFACE_INFO"
  }
}
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_mem
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells sc_mem]
connect_bd_intf_net [get_bd_intf_pins u_kv260/m_axi]  [get_bd_intf_pins sc_mem/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_mem/M00_AXI] [get_bd_intf_pins ps8/S_AXI_HPC0_FPD]
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_ctrl
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells sc_ctrl]
connect_bd_intf_net [get_bd_intf_pins ps8/M_AXI_HPM0_FPD] [get_bd_intf_pins sc_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_ctrl/M00_AXI]    [get_bd_intf_pins u_kv260/s_axil]
connect_bd_net [get_bd_pins u_kv260/irq_out] [get_bd_pins ps8/pl_ps_irq0]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst0
connect_bd_net [get_bd_pins ps8/pl_clk0] \
    [get_bd_pins u_kv260/clk] \
    [get_bd_pins sc_mem/aclk] [get_bd_pins sc_ctrl/aclk] \
    [get_bd_pins ps8/saxihpc0_fpd_aclk] [get_bd_pins ps8/maxihpm0_fpd_aclk] \
    [get_bd_pins rst0/slowest_sync_clk]
connect_bd_net [get_bd_pins ps8/pl_resetn0] [get_bd_pins rst0/ext_reset_in]
connect_bd_net [get_bd_pins rst0/peripheral_aresetn] \
    [get_bd_pins u_kv260/aresetn] \
    [get_bd_pins sc_mem/aresetn] [get_bd_pins sc_ctrl/aresetn]
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

puts "=== validate_bd_design ==="
validate_bd_design
save_bd_design
make_wrapper -files [get_files design_kv260.bd] -top
add_files -norecurse $OUTDIR/proj/ventium_kv260_impl.gen/sources_1/bd/design_kv260/hdl/design_kv260_wrapper.v
set_property top design_kv260_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ---- SYNTH ---------------------------------------------------------------------
puts "=== SYNTH (jobs=$THREADS) ==="
launch_runs synth_1 -jobs $THREADS
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "FAIL: synth_1 did not complete (progress=[get_property PROGRESS [get_runs synth_1]])"
}
puts "IMPL_SYNTH_DONE"

# ---- IMPL: place + route + bitstream -------------------------------------------
set_property strategy Performance_NetDelay_high [get_runs impl_1]
puts "=== IMPL place+route+bitstream (strategy Performance_NetDelay_high) ==="
launch_runs impl_1 -to_step write_bitstream -jobs $THREADS
wait_on_run impl_1
set ist [get_property STATUS   [get_runs impl_1]]
set ipr [get_property PROGRESS [get_runs impl_1]]
puts "=== impl_1 status='$ist' progress=$ipr ==="
open_run impl_1
report_timing_summary -file $OUTDIR/timing_impl.rpt -max_paths 10
report_utilization    -file $OUTDIR/util_impl.rpt
report_drc            -file $OUTDIR/drc_impl.rpt
set wns [get_property STATS.WNS [get_runs impl_1]]
puts "=== IMPL WNS = $wns ns (target ${PL0_MHZ} MHz = [format %.2f [expr 1000.0/$PL0_MHZ]] ns) ==="

# ---- export bitstream + hardware platform (.xsa) -------------------------------
set bit [glob -nocomplain $OUTDIR/proj/ventium_kv260_impl.runs/impl_1/*.bit]
if {$bit ne ""} {
    file copy -force [lindex $bit 0] $OUTDIR/ventium_kv260.bit
    puts "BITSTREAM: $OUTDIR/ventium_kv260.bit"
}
catch {
    write_hw_platform -fixed -include_bit -force $OUTDIR/ventium_kv260.xsa
    puts "XSA: $OUTDIR/ventium_kv260.xsa"
}
puts "IMPL_KV260_DONE wns=$wns bit=[file exists $OUTDIR/ventium_kv260.bit] xsa=[file exists $OUTDIR/ventium_kv260.xsa]"
