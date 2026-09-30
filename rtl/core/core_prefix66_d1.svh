// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// One paid real D1 clock, AP-5005.5. This token stores ONLY its owner PC,
// not an instruction descriptor, opcode, operand, flag, result or prediction.
// Initial admission is flat user mode, where PC==linear PC and context cannot
// change within a live S_PIPE owner. Every mode/event/debug departure kills it.
logic p54_prefix66_context_ok, p54_prefix66_live, p54_prefix66_match;
logic p54_prefix66_paid_q, p54_prefix66_hold, p54_prefix66_fire;
logic p54_prefix66_external_snoop, p54_prefix66_cancel;
logic [31:0] p54_prefix66_pc_q;
assign p54_prefix66_context_ok=!sys_mode && !soc_en && !cosim_en && !def16 &&
    !paging_on && !smm_active && (fbase==32'd0) &&
    !fp_dbg_active && !dbg_step_active;
`ifdef VEN_L1_AXI
// ONLY port0 is independent external DMA. CPU ports1/2 are current core_we
// derived and must NEVER feed fp_issue_block through their request/snoop loop.
assign p54_prefix66_external_snoop=ic_snoop_valid;
`else
assign p54_prefix66_external_snoop=1'b0;
`endif
assign p54_prefix66_live=(state==S_PIPE) && cycle_mode &&
    p54_prefix66_candidate && !pipe_mem_active_q &&
    !fp_occ_pending && !fp_async_pending && !xp_pend && !xs_act && !fx_act &&
    pipe_frontend_ready;
assign p54_prefix66_match=p54_prefix66_paid_q && (p54_prefix66_pc_q==eip);
// Do not block the I-fill/request path until bytes are RESIDENT and RETURNED.
// Otherwise a prefix at a cold line tail can suppress its own required fill.
assign p54_prefix66_hold=p54_prefix66_live &&
    (!p54_prefix66_match || p54_prefix66_external_snoop);
assign p54_prefix66_fire=p54_prefix66_hold && !p54_prefix66_match &&
    !p54_prefix66_external_snoop && !fp_issue_block_base && fsm_case_enabled &&
    (stall_cnt==7'd0) && (pending_mem_pen==7'd0) &&
    (mispred_bubbles==3'd0) && !fp_dbg_active && !dbg_step_active &&
    !smi_take && !nmi_take && !intr_take
`ifdef VEN_FP_PIPE
    && !fp_pipe_rd_haz
`endif
    ;
// Snoop poison is sequential. A qualified consume has register U and
// register/Jcc V only, no pending memory/fragment/FP owner, so it cannot
// itself generate any CPU write snoop. External port0 separately vetoes it.
assign p54_prefix66_cancel=!p54_prefix66_live || exec_flush_all ||
    icsnp_v1 || icsnp_v2 || p54_prefix66_external_snoop ||
    dbg_block_issue || dbg_step_active || fp_dbg_active ||
    smi_take || nmi_take || intr_take || pipe_int_commit;
always_ff @(posedge clk) begin
  if (!rst_n) begin
    p54_prefix66_paid_q<=1'b0;
    p54_prefix66_pc_q<=32'd0;
  end else if (p54_prefix66_cancel) begin
    p54_prefix66_paid_q<=1'b0;
  end else if (p54_prefix66_fire) begin
    p54_prefix66_paid_q<=1'b1;
    p54_prefix66_pc_q<=eip;
  end else if (p54_prefix66_paid_q && (p54_prefix66_pc_q!=eip))
    p54_prefix66_paid_q<=1'b0;
end
`ifndef SYNTHESIS
always_ff @(posedge clk) begin
  if (rst_n) begin
    if (p54_prefix66_hold && (pipe_int_commit || gpr_we!=8'd0 ||
                             pipe_new_mem_req))
      $fatal(1,"PREFIX66: architectural/request side effect before paid D1");
    if (pipe_int_commit && p54_prefix66_candidate &&
        (!p54_prefix66_match || p54_prefix66_external_snoop ||
         pipe_u_eff.is_mem || pipe_u_eff.is_fp || pipe_mem_active_q ||
         (pipe_pair_eff && (pipe_v_eff.is_mem || pipe_v_eff.is_fp ||
                           pipe_v_eff.is_stack || pipe_v_eff.is_lea))))
      $fatal(1,"PREFIX66: unpaid or outside initial register-pair owner");
    if (p54_prefix66_fire && (icsnp_v1 || icsnp_v2))
      $fatal(1,"PREFIX66: real prefix D1 coincided with CPU store owner");
  end
end
`endif
