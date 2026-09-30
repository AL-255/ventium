// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Module-scope, optional raw-byte D1 overlap with the preceding NP's FINAL
// EX clock. Intel AP-500 241799-002 §5.5 p12 permits this prefix overlap;
// p17 explicitly gives MOVZX three EX clocks plus its unhidden prefix clock.
// This is not an EX occupancy credit or a persistent decoded-instruction cache.
// EXPERIMENTAL: NP microcode owns D1; cross-kind overlap still needs explicit
// P54 qualification. AP-500 p18 schedules consecutive MOVSX four clocks apart,
// so EXT->EXT is vetoed rather than claiming three-clock throughput from §5.5.
`ifndef VEN_P54_INT_EXEC_OCC
  initial $fatal(1, "VEN_P54_PREFIX_EX_CHAIN requires VEN_P54_INT_EXEC_OCC");
`endif
`ifndef VEN_PIPE_SDISPATCH
  initial $fatal(1, "VEN_P54_PREFIX_EX_CHAIN requires VEN_PIPE_SDISPATCH");
`endif
`ifndef VEN_PIPE_SDECODE
  initial $fatal(1, "VEN_P54_PREFIX_EX_CHAIN requires VEN_PIPE_SDECODE");
`endif
`ifndef VEN_IC_BRAM
  initial $fatal(1, "VEN_P54_PREFIX_EX_CHAIN requires VEN_IC_BRAM");
`endif

logic [31:0] p54_prefix_ex_flin;
logic p54_prefix_ex_shape_ok, p54_prefix_ex_window_ok, p54_prefix_ex_take;
logic [31:0] p54_prefix_ex_retire_pc_q;
logic p54_prefix_ex_retire_pc_valid_q;
assign p54_prefix_ex_flin = fbase + next_eip;

`ifdef VEN_PIPE_SDISPATCH
always_comb begin
  // Exactly ONE prefix clock may overlap. No 66+0F, segment/address/LOCK/REP,
  // or unknown grammar. All effects of these forms are owned by q_* in EX,
  // not computed from the precommit GPR/flags used by the lookahead decoder.
  p54_prefix_ex_shape_ok =
      ((refdecode_ibuf[0] == 8'h0f) &&
        (((d_kind == K_EXT) &&
           (refdecode_ibuf[1] inside {8'hb6,8'hb7,8'hbe,8'hbf})) ||
         ((d_kind == K_IMUL2) && (refdecode_ibuf[1] == 8'haf)))) ||
      ((refdecode_ibuf[0] == 8'h66) && (d_kind == K_IMUL2) &&
       (d_w == 3'd2) && (refdecode_ibuf[1] inside {8'h69,8'h6b}));
  p54_prefix_ex_shape_ok = p54_prefix_ex_shape_ok &&
      !d_unknown && !d_halt && !d_is_x87 && !d_is_fwait && !d_is_branch &&
      !d_int && !d_int80 && !d_iret && !d_ud2 && !d_rsm && !d_cacheinv &&
      !d_lock && !d_io && (d_sysop == SYS_NONE) && d_writes_reg &&
      !d_mem_write && !d_mem_dst && !d_is_push && !d_is_pop && !d_is_lea &&
      !d_seg_load && !d_store_sreg && !d_push_sreg && !d_pop_sreg &&
      !d_xlat && !d_callf_mem && !d_jmpf_mem &&
      !d_cld && !d_std && !d_cli && !d_sti && !d_clc && !d_stc && !d_cmc &&
      !d_clts && !pfx_addr && !pfx_seg && !pfx_lock && (pfx_rep == 2'd0) &&
      (d_len != 4'd0) &&
      // Only EA is captured from precommit registers. Source/destination
      // register operands are deliberately read after the old write edge.
      (!d_mem_read || (d_addr_mask_known && ((d_addr_mask & gpr_we) == 8'd0)));
end
`else
assign p54_prefix_ex_shape_ok = 1'b0;
`endif

`ifdef VEN_IC_BRAM
// Next full16B window is at most31B from the older start (old length<=15),
// so the existing consecutive A/B ports suffice. Residency alone is never a
// permit: verify returned set+way+collision identities on the CONSUME edge.
assign p54_prefix_ex_window_ok =
    (p54_prefix_ex_flin[11:0] <= 12'(4096 - IWORDS*4)) &&
    ic_buffered(p54_prefix_ex_flin) &&
    ic_buffered(p54_prefix_ex_flin + 32'(IWORDS*4 - 1));
`else
assign p54_prefix_ex_window_ok = 1'b0;
`endif

assign p54_prefix_ex_take = cycle_mode && (state == S_EXEC) && fsm_case_enabled &&
    // These current owners always retire in the successful normal EX arm.
    // Exclude every alternate effect/dispatch, not just the kind field.
    (q_kind inside {K_EXT,K_IMUL2}) && (q_sysop == SYS_NONE) && q_writes_reg &&
    !q_mem_write && !q_mem_dst && !q_is_branch && !q_is_push && !q_is_pop &&
    !q_is_lea && !q_is_x87 && !q_io && !q_lock && !q_seg_load &&
    !q_store_sreg && !q_push_sreg && !q_pop_sreg && !q_xlat &&
    !q_callf_mem && !q_jmpf_mem && !q_cld && !q_std && !q_cli && !q_sti &&
    !q_clc && !q_stc && !q_cmc && !q_clts && (q_len != 4'd0) && (eip == q_pc) &&
    !sys_mode && !soc_en && !cosim_en && !def16 && !paging_on && !smm_active &&
    (fbase == 32'd0) && !fold_pending_r &&
    !dbg_block_issue && !dbg_step_active && !fp_dbg_active &&
    !tf_at_issue && !rf_at_issue &&
`ifdef VEN_DBG_CORE
    // dbg_bp_hit only checks S_PIPE/S_DECODE; this is a new issue boundary.
    !(dbg_bp_en && (next_eip == dbg_bp_addr)) &&
`endif
    !smi_take && !nmi_take && !intr_take &&
    !fp_occ_pending && !fp_async_pending && !pipe_mem_active_q &&
`ifdef VEN_FP_PIPE
    !fpp_valid &&
`ifdef VEN_FP_PIPE2
    !fpp2_valid &&
`endif
`endif
    !xp_pend && !xs_act && !fx_act &&
    (pending_mem_pen == 7'd0) && (stall_cnt == 7'd0) && (mispred_bubbles == 3'd0) &&
    exec_issue_ok && !icsnp_v1 && !icsnp_v2 &&
`ifdef VEN_L1_AXI
    !ic_snoop_valid &&
`endif
    !((q_kind == K_EXT) && (d_kind == K_EXT)) &&
    p54_prefix_ex_shape_ok && p54_prefix_ex_window_ok;

// q_pc changes to the NEXT owner on the same edge as the OLD retire pulse.
// Hold that old fetch PC through the delayed DPI/debug retirement observation;
// GPR/flags snapshots stay live and contain only the old commit at that time.
always_ff @(posedge clk) begin
  if (!rst_n) begin
    p54_prefix_ex_retire_pc_valid_q <= 1'b0;
    p54_prefix_ex_retire_pc_q <= 32'd0;
  end else begin
    p54_prefix_ex_retire_pc_valid_q <= p54_prefix_ex_take;
    if (p54_prefix_ex_take) p54_prefix_ex_retire_pc_q <= q_pc;
  end
end

`ifndef SYNTHESIS
logic p54_prefix_ex_log_en;
initial p54_prefix_ex_log_en = $test$plusargs("ven_prefix_chainlog") != 0;
always_ff @(posedge clk) begin
  if (rst_n) begin
    if (p54_prefix_ex_retire_pc_valid_q && !retire_valid)
      $fatal(1, "PREFIX_EX_CHAIN: retirement PC override without old retire");
`ifdef VEN_P54_INT_EXEC_OCC
    if (p54_prefix_ex_retire_pc_valid_q && (state == S_EXEC) &&
        (!p54_int_exec_hold || p54_int_exec_active_q))
      $fatal(1, "PREFIX_EX_CHAIN: next operation inherited old EX ownership");
`endif
    if (p54_prefix_ex_log_en && p54_prefix_ex_take)
      $display("[P54PREFIXCHAIN] old_pc=%08x next_pc=%08x old_kind=%0d next_kind=%0d mem=%0b",
               q_pc, next_eip, q_kind, d_kind, d_mem_read);
  end
end
`endif
