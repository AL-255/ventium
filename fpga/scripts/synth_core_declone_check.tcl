# Synthesize -top core IN-CONTEXT in the EXACT deployed fetch config to see whether the
# uopcache store_slots_a/b RAMs DECLONE (the residual fast-path fetch corruption), the
# same way u_icache/ic_line_a decloned in the icache probe logs. Watch [Synth 8-223].
set ROOT [file normalize [file dirname [info script]]/../..]
set OUT  $ROOT/fpga/build/core_declone
file mkdir $OUT
set PART xck26-sfvc784-2LV-c
create_project -in_memory -part $PART core_dcl
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
}
foreach f $svfiles { read_verilog -sv $ROOT/rtl/$f }
synth_design -top core -part $PART -mode out_of_context -flatten_hierarchy rebuilt \
  -include_dirs [list $ROOT/rtl/core $ROOT/rtl/fpu] \
  -verilog_define {SYNTHESIS VTM_NO_DPI VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE VEN_FP_PIPE2 VEN_CACHE_HALF VEN_IC_BRAM VEN_BTB_PIPE VEN_UOPCACHE VEN_FE_PIPE VEN_FP_PC_RELAX VEN_FPREM}
puts "=== RAMB36E2 cells by array name (a vs b survival) ==="
foreach pat {ic_line_a ic_line_b store_slots_a store_slots_b store_bmap_a store_bmap_b} {
  puts "  $pat : [llength [get_cells -hier -regexp ".*${pat}.*" -filter {REF_NAME =~ RAMB*}]] RAMB"
}
puts "CORE_DECLONE_DONE"
