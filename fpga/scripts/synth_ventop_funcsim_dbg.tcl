# Synthesize ventium_top (deployed FreeDOS fetch config) to a funcsim netlist for an
# xsim GATE-LEVEL boot of FreeDOS — the real RAMB36 fetch RAMs (the board-only bug)
# in a controllable sim. VTM_NO_DPI strips the retire-DPI (synth can't have DPI).
#
# *** _dbg variant ***: synthesizes WITH +VEN_DBG_CORE so the netlist ventium_top
# exposes the dbg_* observability ports (committed EIP/CS/ESP/EFLAGS, FSM state,
# last vector, fault PC, retire_valid, comparator/freeze seam). The GLS tb taps
# these (GLS_DBG=1 in run_gls_freedos.sh) for a committed-PC + retire trajectory
# dump on a wedge/fault — making the GLS a real fetch-bug hunt platform.
set ROOT [file normalize [file dirname [info script]]/../..]
set OUT  $ROOT/fpga/build/ventop_funcsim_dbg
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART vtop_fs
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
}
foreach f $svfiles { read_verilog -sv $ROOT/rtl/$f }
synth_design -top ventium_top -part $PART -mode out_of_context -flatten_hierarchy rebuilt \
  -include_dirs [list $ROOT/rtl/core $ROOT/rtl/fpu] \
  -verilog_define {SYNTHESIS VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_FP_PIPE2 VEN_CACHE_HALF VEN_IC_BRAM VEN_BTB_PIPE VEN_UOPCACHE VEN_FE_PIPE VEN_FP_PC_RELAX VEN_FPREM VEN_L1_AXI VEN_KV260_SOC VEN_DBG_CORE}
report_utilization -file $OUT/util.rpt
write_verilog -force -mode funcsim $OUT/ventium_top_funcsim_dbg.v
puts "VENTOP_FUNCSIM_DBG_DONE -> $OUT/ventium_top_funcsim_dbg.v"
