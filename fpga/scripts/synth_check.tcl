# Fast Vivado RTL-elaboration check for the core (catches IEEE-1800/synth syntax that
# Verilator accepts but Vivado rejects, e.g. Synth 8-12513). OOC, -rtl only (~2 min).
#   vivado -mode batch -source fpga/scripts/synth_check.tcl
set ROOT [file normalize [file dirname [info script]]/../..]
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART
# Same define set as the hpc40 respin (FPTRAP + FPREM + UOPCACHE + FE_PIPE + ...).
# TRANSCENDENTAL is OFF (its 4 iterative engines are ~2x over the xck26); FPATAN is
# PS-trapped instead (VEN_FPTRAP). Set FPTRAP=0 + TRANSCENDENTAL below to check that path.
set DEFS {SYNTHESIS VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER \
    VEN_FP_PIPE VEN_FP_PIPE2 VEN_CACHE_HALF VEN_L1_AXI VEN_KV260_SOC \
    VEN_IC_BRAM VEN_BTB_PIPE VEN_UOPCACHE VEN_FE_PIPE VEN_DBG_CORE VEN_PS_PROXY \
    VEN_FP_PC_RELAX VEN_FPTRAP VEN_FPREM}
set svfiles {
    ventium_pkg.sv core/ventium_alu_pkg.sv core/ventium_decode_pkg.sv
    fpu/fpu_x87_pkg.sv core/ventium_sys_pkg.sv core/ventium_x87_pkg.sv
    ventium_top.sv
    core/core.sv core/bpred_btb.sv core/decode.sv core/issue_uv.sv core/ven_idiv.sv
    fpu/fpu_top.sv fpu/fpu_srt_div.sv fpu/fpu_sqrt_iter.sv fpu/ven_bcd.sv fpu/ven_bcd_to_fp.sv
    fpu/fpu_fpatan.sv fpu/fpu_fyl2x.sv fpu/fpu_fsincos.sv fpu/fpu_f2xm1.sv fpu/fpu_fprem.sv
    mem/dcache_timing.sv mem/icache.sv mem/uopcache.sv mem/tlb.sv
    bus/biu_p5.sv bus/biu.sv
    mem/ven_l1d.sv mem/ven_axi_master.sv mem/ventium_l1_axi.sv
    soc/ven_soc_axil.sv soc/ven_soc_dbg.sv soc/ventium_kv260_core.sv soc/ven_fan_ctrl.sv
}
foreach f $svfiles { read_verilog -sv $ROOT/rtl/$f }
read_verilog $ROOT/rtl/soc/ventium_kv260_top.v
read_verilog $ROOT/rtl/soc/ven_fan_ctrl_top.v
synth_design -top ventium_kv260_top -part $PART -mode out_of_context \
    -include_dirs [list $ROOT/rtl/core $ROOT/rtl/fpu] \
    -verilog_define $DEFS -rtl
puts "SYNTH_CHECK_ELAB_OK"
