// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Optional plain MOV source service: the final validated load acknowledgement
// is MOV's one EX clock, not a preliminary edge followed by a redundant EX.
// The existing fragment/TLB/fault sequencer still owns the request and ACK.
logic [31:0] p54_mov_ack_load_value;
logic p54_mov_ack_shape_ok, p54_mov_ack_take;

// One merge authority feeds BOTH the ordinary S_LOAD capture and the existing
// GPR writeback driver. Never consume raw fragment two as a complete operand.
assign p54_mov_ack_load_value = xp_pend
  ? ((xp_lo & ~(32'hffff_ffff << {xp_first,3'd0})) |
     (mem_rdata << {xp_first,3'd0}))
  : mem_rdata;

// ibuf still belongs to q_pc in S_LOAD. At most one ordinary prefix is proven
// by checking its first two bytes; don't infer prefix count from operand width.
// A single 66 still pays capture D1 plus the source-service EX edge. Exotic
// prefix/system/debug/folded forms retain their existing conservative path.
assign p54_mov_ack_shape_ok = cycle_mode && (state==S_LOAD) &&
  !sys_mode && !soc_en && !cosim_en && !def16 && !paging_on && !smm_active &&
  (fbase==32'd0) &&
  !fold_pending_r && !dbg_block_issue && !dbg_step_active && !fp_dbg_active &&
  !tf_at_issue && !rf_at_issue && !fp_async_pending && !fp_occ_pending &&
  (q_pc==eip) && (q_len!=4'd0) &&
  (!is_prefix(ibuf[0]) || !is_prefix(ibuf[1])) &&
  (q_kind==K_ALU) && q_is_mov && (q_alu_op==ALU_MOV) &&
  (q_sysop==SYS_NONE) && q_mem_read && !q_mem_write && !q_mem_dst &&
  q_writes_reg && !q_writes_flags && !q_use_imm &&
  (q_w inside {3'd1,3'd2,3'd4}) &&
  !q_is_push && !q_is_pop && !q_is_lea && !q_is_branch && !q_is_x87 &&
  !q_seg_load && !q_store_sreg && !q_push_sreg && !q_pop_sreg && !q_xlat &&
  !q_callf_mem && !q_jmpf_mem && !q_io && !q_lock &&
  !q_cld && !q_std && !q_cli && !q_sti &&
  !q_clc && !q_stc && !q_cmc && !q_clts;

// mem_ack is the FSM-visible, fragment-completed ACK, not raw bus_ack. The
// first legacy page fragment has xp_cross and cannot expose GPR/PC/retirement.
// fsm_case_enabled suppresses all translation, protection, and EX diversions.
assign p54_mov_ack_take = p54_mov_ack_shape_ok && mem_ack && !xp_cross &&
                          fsm_case_enabled && !fp_async_fault_hold;
