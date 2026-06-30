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
    core/regfile.sv core/decode_stages.sv core/uv_common.sv core/u_pipe.sv core/v_pipe.sv core/fpu_writeback.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    fpu/fpu_fpatan.sv fpu/fpu_fyl2x.sv fpu/fpu_fsincos.sv fpu/fpu_f2xm1.sv fpu/fpu_fprem.sv
    mem/dcache_timing.sv mem/icache.sv mem/uopcache.sv mem/tlb.sv
    bus/biu_p5.sv bus/biu.sv
    mem/ven_l1d.sv mem/ven_axi_master.sv mem/ventium_l1_axi.sv
    soc/ven_soc_axil.sv soc/ven_soc_dbg.sv soc/ventium_kv260_core.sv
    soc/ven_fan_ctrl.sv
}
foreach f $svfiles { add_files -norecurse $ROOT/rtl/$f }
# RTL_IRQ=1: the in-PL 8254 PIT + 8259 PIC (DOS-Quake #DE fix; see the DEFS note below).
if {[envor RTL_IRQ 0]} {
    add_files -norecurse $ROOT/rtl/soc/ven_pic.sv
    add_files -norecurse $ROOT/rtl/soc/ven_pit.sv
}
add_files -norecurse $ROOT/rtl/soc/ventium_kv260_top.v
add_files -norecurse $ROOT/rtl/soc/ven_fan_ctrl_top.v
set_property file_type SystemVerilog [get_files *.sv]
add_files -norecurse [glob $ROOT/rtl/core/*.svh]
add_files -norecurse [glob $ROOT/rtl/fpu/*.svh]
set_property file_type {Verilog Header} [get_files *.svh]
set_property include_dirs [list $ROOT/rtl/core $ROOT/rtl/fpu] [current_fileset]
# uop-cache + half-cache + 2-stage FP commit (routable, 65.3 MHz OOC) + SoC seams.
set DEFS {SYNTHESIS VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER \
    VEN_FP_PIPE VEN_FP_PIPE2 VEN_CACHE_HALF \
    VEN_L1_AXI VEN_KV260_SOC}
# RTL_IRQ=1 (default OFF): the DOS-Quake #DE FIX. Move the 8254 PIT + 8259 PIC from the
# PS C-models INTO the PL (ven_pit/ven_pic in ventium_top behind VEN_RTL_IRQ), with IR0
# from a DENSE fixed-cycle square wave (VEN_RTL_IRQ_FIXED, period VEN_FIXED_IRQ0_CYC=4000
# core-clk). The sparse PS-modeled IRQ0 never preempts CWSDPMI's int-0x31 reflector (->
# the 0x60 task resumes at cs=0x2b CPL3 running CPL0 code -> #GP); a dense in-PL IRQ0 does
# (-> the timer's cs=0x18 CPL0 dispatch -> clean). Proven in l1axi_kv_dos_q_rtlirq sim
# (sim==board: #GP=0 to 13M insns vs every PIT cadence faulting @retire 8.46M). OFF default.
if {[envor RTL_IRQ 0]} { lappend DEFS VEN_RTL_IRQ VEN_RTL_IRQ_FIXED "VEN_FIXED_IRQ0_CYC=[envor FIXED_IRQ0_CYC 4000]" }
# IC_BRAM=0 drops the RAMB36 icache line buffer for the LUTRAM (distributed)
# path — used to test whether the board-only upper-fetch-word corruption is the
# BRAM cross-port read path (the RAMB36 collision is not modeled by Verilator).
if {[envor IC_BRAM 1]} { lappend DEFS VEN_IC_BRAM }
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
# PS_PROXY=1 builds the F4 USERSPACE-QUAKE BITSTREAM: the int-0x80 syscall window
# (ven_soc_axil 0x40-0x6C) + the gated S_SYSCALL_WAIT core stall, so the PS daemon
# (ven_soc_app --quake) services Linux syscalls for a userspace ELF. The macro only
# ADDS a stall arm that is dead when proxy_en=0, so a PS_PROXY=1 build stays
# byte/cycle-identical to production unless the PS sets MODE.PROXY_EN; the module
# port list is unchanged (the seam is internal to ventium_kv260_core), so the BD/
# address map need no change. OFF by default.
if {[envor PS_PROXY 0]} { lappend DEFS VEN_PS_PROXY }
# FP_PC_RELAX=1 (default ON): relax the x87 precision-control loud-HALT (f_pc_bad)
# so FP arithmetic under PC!=11 (24-bit single / 53-bit double) proceeds instead of
# halting. Quake's rasterizer (R_RecursiveWorldNode) runs FSUBR/FMUL under single
# precision via fldcw; the gate HALTed the render. Result is full-80-bit-then-RC
# (more precise than P5, benign — Quake stores back to f32). make verify never runs
# arith under PC!=11 so the base build (no define) stays byte-identical.
if {[envor FP_PC_RELAX 1]} { lappend DEFS VEN_FP_PC_RELAX }
# TRANSCENDENTAL=1 (default ON): the iterative x87 transcendental unit (fpu_fpatan/
# fpu_fyl2x/fpu_fsincos/fpu_f2xm1 + S_TRSC_BUSY). Quake's glibc atan() issues D9 F3
# FPATAN (the ONLY transcendental Quake uses) — without this the core loud-HALTs on
# the first FPATAN (board-confirmed: retire ~2.4B @0x809aaf5). Adds area; pairs with
# UOPCACHE=1 (which frees LUTs by deleting the byte-gather MUXF wall). Set 0 to omit.
if {[envor TRANSCENDENTAL 1]} { lappend DEFS VEN_TRANSCENDENTAL }
# FPREM=1 (default ON): the exact partial-remainder engine (fpu_fprem) for D9 F8 FPREM.
# Quake's glibc fmodl issues one FPREM; without this the core loud-HALTs on it. Without
# the define D9 F8 stays DEFERRED (loud HALT) — base build unchanged.
if {[envor FPREM 1]} { lappend DEFS VEN_FPREM }
# FPTRAP=0 (default OFF): PS-trap FPATAN instead of the HW transcendental engine. On
# D9 F3 the core stalls in S_FPTRAP_WAIT exposing ST0/ST1; the A53 (ven_soc_app)
# computes atan2 and commits ST1<-result+pop via the 0xEC-0xFC reg window. Use this
# WITH TRANSCENDENTAL=0 to fit the xck26 (the 4 iterative engines are ~2x over). The
# two are mutually exclusive for D9 F3 decode — never set both to 1.
if {[envor FPTRAP 0]} { lappend DEFS VEN_FPTRAP }
# FP_PS_ALL=1 (default OFF): the STRATEGIC AREA-RELIEF build. Remove the ENTIRE x87
# COMPUTE datapath from the PL (the iterative engines fpu_srt_div/fpu_sqrt_iter/
# fpu_fpatan/fyl2x/fsincos/f2xm1/fprem + ven_bcd + the fx_add/fx_mul/fx_div/fx_sqrt/
# compare/frndint/fscale combinational cones in fpu_writeback) and PS-TRAP every x87
# arithmetic/compare/transcendental op to the A53 (ven_soc_app, SoftFloat extF80).
# The small x87 STATE FILE (fpu_top: 8x80 stack + cw/sw/tag) + the data-movement ops
# (FLD/FST/FILD/FIST/FXCH/FLDCONST/FNINIT/...) STAY in PL. Frees a large amount of LUT
# so the xck26 routes with low congestion -> route_design/phys_opt_design get room to
# insert real hold-fixing delay on the marginal uopcache fetch-path hold paths (the
# F4A board-only DOS-Quake fetch #DE root cause). Implies VEN_FPTRAP (the trap seam)
# and FORCES the iterative engines OFF (they are the bulk of the area being removed).
if {[envor FP_PS_ALL 0]} {
    lappend DEFS VEN_FP_PS_ALL VEN_FPTRAP
    # strip the iterative-engine defines so the engines are NOT instantiated and their
    # combinational fallbacks in fpu_writeback are the pruned (gated-to-const) arms.
    set DEFS [lsearch -all -inline -not -exact $DEFS VEN_TRANSCENDENTAL]
    set DEFS [lsearch -all -inline -not -exact $DEFS VEN_FPREM]
    set DEFS [lsearch -all -inline -not -exact $DEFS VEN_SRT_ITER]
    set DEFS [lsearch -all -inline -not -exact $DEFS VEN_BCD_ITER]
    set DEFS [lsearch -all -inline -not -exact $DEFS VEN_FP_PIPE]
    set DEFS [lsearch -all -inline -not -exact $DEFS VEN_FP_PIPE2]
    puts "=== FP_PS_ALL=1: x87 COMPUTE datapath removed from PL; all FP ops PS-trapped (SoftFloat extF80 on A53). Iterative engines + fx_* cones gated out. ==="
}
set_property verilog_define $DEFS [current_fileset]

# FAN_CTRL=1 (default ON): add the temperature-controlled cooling fan — a PL
# SYSMONE4 (System Management Wizard) feeding ven_fan_ctrl, which PWM-drives the
# fan transistor on package pin A12. Fully hardware (no PS); the fan_pin external
# port + its A12 constraint exist ONLY in this build. Set FAN_CTRL=0 to omit.
set FANCTRL [envor FAN_CTRL 1]
if {$FANCTRL} {
    add_files -fileset constrs_1 -norecurse $ROOT/fpga/constraints/fan.xdc
}
update_compile_order -fileset sources_1

# ---- block design (identical topology to bd_kv260_soc.tcl) ----------------------
create_bd_design design_kv260
set psvlnv [lindex [lsort [get_ipdefs xilinx.com:ip:zynq_ultra_ps_e:*]] end]
create_bd_cell -type ip -vlnv $psvlnv ps8
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset 1} [get_bd_cells ps8]
set_property -dict [list \
    CONFIG.PSU__USE__S_AXI_GP0 {1} \
    CONFIG.PSU__SAXIGP0__DATA_WIDTH [envor HPC0_WIDTH 128] \
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

# ---- temperature-controlled cooling fan (FAN_CTRL) -----------------------------
# A PL SYSMONE4 (System Management Wizard, INTERFACE=Enable_AXI + ENABLE_TEMP_BUS:
# continuous on-die temperature -> temp_out[9:0] + eos_out; clocked by s_axi_aclk)
# feeds ven_fan_ctrl_top (the .v BD shell over ven_fan_ctrl.sv), which maps the
# temperature to an 8-bit PWM driving fan_pin (A12). The fan PWM loop is pure
# hardware (continuous sequencer auto-runs after reset); the wizard's S_AXI_LITE
# is wired to the control SmartConnect (sc_ctrl M01) for optional PS readback/
# reconfig. Port/CONFIG names verified against the IP (system_management_wiz 1.3).
if {$FANCTRL} {
    set smvlnv [lindex [lsort [get_ipdefs xilinx.com:ip:system_management_wiz:*]] end]
    create_bd_cell -type ip -vlnv $smvlnv sysmon
    set_property -dict [list \
        CONFIG.INTERFACE_SELECTION {Enable_AXI} \
        CONFIG.ENABLE_TEMP_BUS {true} \
        CONFIG.SEQUENCER_MODE {Continuous} \
        CONFIG.DCLK_FREQUENCY $PL0_MHZ ] [get_bd_cells sysmon]
    # S_AXI_LITE of the wizard -> a second master on sc_ctrl (M00 already -> u_kv260)
    set_property CONFIG.NUM_MI {2} [get_bd_cells sc_ctrl]
    connect_bd_intf_net [get_bd_intf_pins sc_ctrl/M01_AXI] [get_bd_intf_pins sysmon/S_AXI_LITE]
    connect_bd_net [get_bd_pins ps8/pl_clk0]              [get_bd_pins sysmon/s_axi_aclk]
    connect_bd_net [get_bd_pins rst0/peripheral_aresetn] [get_bd_pins sysmon/s_axi_aresetn]
    # the fan controller (Verilog BD shell over the SV implementation)
    create_bd_cell -type module -reference ven_fan_ctrl_top u_fan
    set_property -dict [list CONFIG.CLK_HZ [expr {$PL0_MHZ * 1000000}]] [get_bd_cells u_fan]
    connect_bd_net [get_bd_pins ps8/pl_clk0]              [get_bd_pins u_fan/clk]
    connect_bd_net [get_bd_pins rst0/peripheral_aresetn] [get_bd_pins u_fan/rst_n]
    connect_bd_net [get_bd_pins sysmon/temp_out] [get_bd_pins u_fan/temp]
    connect_bd_net [get_bd_pins sysmon/eos_out]  [get_bd_pins u_fan/eos]
    create_bd_port -dir O fan_pin
    connect_bd_net [get_bd_ports fan_pin] [get_bd_pins u_fan/fan_pwm]
    # Vp_Vn (external-analog interface) left unconnected — internal temperature only.
}
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
# Synthesize the out-of-context module-reference / IP runs FIRST and WAIT for them,
# so the top synth_1 + opt_design see the resolved OOC checkpoints (not black-box
# stubs). Launching synth_1 alone can race the parallel OOC runs and leave
# 'design_kv260_u_kv260_0' a black box at opt_design (DRC INBB-3). Explicitly
# draining the child synth runs before the top + impl is the deterministic order.
puts "=== SYNTH (jobs=$THREADS) ==="
set child_synth {}
foreach r [get_runs *_synth_1] {
    if {$r ne "synth_1"} { lappend child_synth $r }
}
if {[llength $child_synth] > 0} {
    puts "=== OOC child synth runs first: $child_synth ==="
    launch_runs $child_synth -jobs $THREADS
    foreach r $child_synth { wait_on_run $r }
}
launch_runs synth_1 -jobs $THREADS
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "FAIL: synth_1 did not complete (progress=[get_property PROGRESS [get_runs synth_1]])"
}
puts "IMPL_SYNTH_DONE"

# ---- IMPL: place + route + bitstream -------------------------------------------
# IMPL_STRATEGY env override: e.g. Congestion_SpreadLogic_high relieves routing
# congestion (AltSpreadLogic_high placement + phys_opt + Explore routing).
set IMPLSTRAT [envor IMPL_STRATEGY Performance_NetDelay_high]
set_property strategy $IMPLSTRAT [get_runs impl_1]
# HOLD_FIX=1: run post-route `phys_opt_design -hold_fix` (after tightening the hold
# requirement via HOLD_UNC clock uncertainty) to give the marginal uopcache BRAM-write
# hold paths real silicon margin — the F4A board-only fetch #DE fix. Needs routing room,
# so pair with congestion relief (UOPCACHE=0 / fewer features / bigger device).
if {[envor HOLD_FIX 0]} {
    set_property STEPS.ROUTE_DESIGN.TCL.POST $ROOT/fpga/scripts/post_route_holdfix.tcl [get_runs impl_1]
    puts "=== HOLD_FIX=1: post-route phys_opt_design -hold_fix enabled (HOLD_UNC=[envor HOLD_UNC 0.150] ns) ==="
}
puts "=== IMPL place+route+bitstream (strategy $IMPLSTRAT) ==="
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
