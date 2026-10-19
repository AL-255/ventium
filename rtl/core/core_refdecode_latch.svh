// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// One capture point for the reference decoder's complete instruction record.
// S_DECODE retains its existing event/fault dispatch. VEN_PIPE_SDISPATCH may
// reuse this exact capture for a checked integer handoff from resident bytes;
// neither path copies or independently reconstructs the decoded fields.
// Ordinary callers pass eip; optional last-EX overlap passes the next owner PC.
task automatic capture_reference_decode(input logic [31:0] capture_pc);
  q_len<=d_len; q_is_branch<=d_is_branch; q_branch_taken<=d_branch_taken;
  q_rel<=d_rel; q_alu_op<=d_alu_op; q_writes_reg<=d_writes_reg;
  q_writes_flags<=d_writes_flags; q_mem_read<=d_mem_read; q_mem_write<=d_mem_write;
  q_lock<=d_lock;
  q_mem_dst<=d_mem_dst; q_dst_reg<=d_dst_reg; q_src_reg<=d_src_reg; q_imm<=d_imm;
  q_use_imm<=d_use_imm; q_is_push<=d_is_push; q_is_pop<=d_is_pop; q_is_lea<=d_is_lea;
  q_is_mov<=d_is_mov; q_ea<=d_ea; q_pc<=capture_pc; q_w<=d_w; q_dst_high8<=d_dst_high8;
  q_src_high8<=d_src_high8; q_kind<=d_kind; q_shrot<=d_shrot; q_shift_cl<=d_shift_cl;
  q_shift_one<=d_shift_one; q_shift_imm<=d_shift_imm; q_shrd<=d_shrd; q_md<=d_md;
  q_imul_3op<=d_imul_3op; q_imul_imm<=d_imul_imm; q_ext_signed<=d_ext_signed;
  q_ext_srcw<=d_ext_srcw; q_cc<=d_cc; q_bit_imm<=d_bit_imm; q_bit_op<=d_bit_op;
  q_conv_cdq<=d_conv_cdq; q_sm<=d_sm; q_st<=d_st; q_rep<=(pfx_rep==2'd3);
  q_repne<=(pfx_rep==2'd2); q_str_loadsi<=d_str_loadsi; q_str_storedi<=d_str_storedi;
  q_str_scandi<=d_str_scandi; q_ct<=d_ct; q_ret_imm<=d_ret_imm;
  q_cld<=d_cld; q_std<=d_std; step<=4'd0;
  q_clc<=d_clc; q_stc<=d_stc; q_cmc<=d_cmc; q_cnt16<=d_cnt16;
  q_cli<=d_cli; q_sti<=d_sti; q_br16<=d_br16; q_clts<=d_clts; q_lmsw<=d_lmsw;
  // Consume a shadow only at an admitted instruction boundary. S_DECODE
  // still checks the PRE-edge shadow before event dispatch, exactly as before.
  if (!dbg_block_issue) irq_shadow <= 1'b0;
  q_io<=d_io; q_io_write<=d_io_write; q_io_w<=d_io_w;
  q_io_port<= d_io_imm ? {8'd0, d_io_port_imm} : gpr_o[R_EDX][15:0];
  q_fxop<=d_fxop; q_is_x87<=d_is_x87; q_f_mem_read<=d_f_mem_read;
  q_f_mem_write<=d_f_mem_write; q_f_mbytes<=d_f_mbytes; q_f_pop<=d_f_pop;
  q_f_pop2<=d_f_pop2; q_f_sti<=d_f_sti; q_f_aluop<=d_f_aluop; q_f_const<=d_f_const;
  f_step<=4'd0;
  q_sysop<=d_sysop; q_sys_sreg<=d_sys_sreg; q_sys_creg<=d_sys_creg;
  q_seg<=d_seg; q_pfx_seg_en<=d_pfx_seg_en; q_ljmp_off<=d_ljmp_off; q_ljmp_sel<=d_ljmp_sel;
  q_seg_load<=d_seg_load; q_lseg<=d_lseg;
  q_push_sreg<=d_push_sreg; q_pop_sreg<=d_pop_sreg;
  q_seg_load_lo<=d_seg_load_lo;
  q_store_sreg<=d_store_sreg;
  q_xlat<=d_xlat;
  q_callf_mem<=d_callf_mem; q_jmpf_mem<=d_jmpf_mem;
  seg_step<=1'b0;
endtask
