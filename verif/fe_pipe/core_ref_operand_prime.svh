// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Private experiment: lend the reference-dispatch edge to the EXISTING
// resident-only D-cache port. Never launch a transaction, own a translation,
// execute an instruction, or shorten its required execution occupancy here.
logic ref_prime_select, ref_prime_offer, ref_prime_commit;
logic [3:0] ref_prime_bytes;
logic [3:0] ref_prime_strb;
`ifdef VEN_REF_OPERAND_PRIME
`ifndef VEN_RAW_V_READ_PRIME
  initial $fatal(1, "reference operand prime requires the raw resident port");
`endif
`ifndef VEN_PIPE_SDISPATCH_SHORT
  initial $fatal(1, "reference operand prime requires checked reference dispatch");
`endif
`ifndef VEN_FP_SCALAR_DISPATCH
  initial $fatal(1, "reference operand prime requires checked scalar dispatch");
`endif
  // QUERY selection depends only on pre-edge decode/owner state, NEVER on
  // ready, ACK, a translated permission result or the final FSM permit.
  // Fast-path descriptors and their established priming arbitration retain
  // priority. The integer case must actually be a reference-only instruction.
  assign ref_prime_select = (state == S_PIPE) && cycle_mode && real_bus &&
      !pipe_mem_active_q && !mc_valid_q && !mc_fp_self_prime &&
      !mc_held_read_prime && !mc_fresh_read_prime && !pipe_pair_lookahead &&
      ((!pipe_u_eff.is_fp && !pipe_u_eff.simple && !d_is_x87 &&
        pipe_sdispatch_shape_ok && d_mem_read && !d_mem_write &&
        (d_kind inside {K_ALU, K_EXT, K_MULDIV, K_IMUL2})) ||
       ((pipe_u_eff.is_fp || !pipe_u_eff.simple) && d_is_x87 &&
        d_f_mem_read && !d_f_mem_write &&
        (d_fxop inside {FX_AR_I32, FX_FCOM_M32, FX_FCOM_M64})));
  // The old resident port supports byte or full-word reads. A 16-bit source
  // can use a four-byte resident window only when all four bytes are safely
  // in the same mapped line and segment. The subsequent architectural request
  // keeps its original exact two-byte strobe and owns every fault check.
  assign ref_prime_bytes = d_is_x87 ? d_f_mbytes :
      ((d_kind == K_EXT) ? {1'b0, d_ext_srcw} : {1'b0, d_w});
  assign ref_prime_strb = (ref_prime_bytes == 4'd1) ? 4'h1 : 4'hf;
  assign ref_prime_offer = ref_prime_select && mc_boundary_ok &&
      (ref_prime_bytes inside {4'd1, 4'd2, 4'd4, 4'd8}) &&
      ({1'b0, d_ea} + ((ref_prime_bytes == 4'd1) ? 33'd0 :
                       (ref_prime_bytes == 4'd8) ? 33'd7 : 33'd3)
          <= {1'b0, seg_limit[d_seg]}) &&
      (mc_query_lin[4:0] <= ((ref_prime_bytes == 4'd1) ? 5'd31 :
                            (ref_prime_bytes == 4'd8) ? 5'd24 : 5'd28)) &&
      (!paging_on || (mc_lookup_hit && mc_lookup_perm[0] &&
                      ((eff_cpl != 2'd3) || mc_lookup_perm[2]))) &&
      (!sys_mode || (sys_fp_ok && !real_mode && !v86 && cs_d &&
        seg_pm_loaded[d_seg] && (seg_sel[d_seg][15:2] != 0) &&
        seg_attr[d_seg][7] && seg_attr[d_seg][4] &&
        !seg_attr[d_seg][3] && !seg_attr[d_seg][2] &&
        ((eff_cpl <= seg_attr[d_seg][6:5]) &&
         (seg_sel[d_seg][1:0] <= seg_attr[d_seg][6:5]))));
  // Mirror only a checked handoff. The ordinary FSM still captures the SAME
  // reference packet and enters S_LOAD/S_FLOAD. No request or command is
  // accepted early. If the cache cannot lend its port, nothing changes.
  assign ref_prime_commit = ref_prime_offer && pipe_fp_live_arm &&
      !pipe_fetch_checked_handoff && !rep_stos_cont_recovery_need &&
      !rep_stos_cont_take && !fp_dbg_active && !dbg_step_active &&
      !dbg_block_issue && !irq_shadow && !pipe_agi &&
      (mispred_bubbles == 0) &&
      ((!d_is_x87 && fp_sys_bail && pipe_sdispatch_short_window_ok) ||
       (d_is_x87 && pipe_fp_scalar_dispatch_ok &&
        !fp_shared_mem_admit && !fp_shared_direct))
`ifdef VEN_FP_PIPE
      && !fp_pipe_rd_haz
`endif
      ;
`ifndef SYNTHESIS
  logic ref_prime_check_q, ref_prime_fp_q;
  logic [31:0] ref_prime_pc_q, ref_prime_ea_q;
  logic [2:0] ref_prime_seg_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ref_prime_check_q <= 1'b0;
      ref_prime_fp_q <= 1'b0;
      ref_prime_pc_q <= 0; ref_prime_ea_q <= 0; ref_prime_seg_q <= 0;
    end else begin
      if (ref_prime_check_q)
        assert (state == (ref_prime_fp_q ? S_FLOAD : S_LOAD) &&
                q_pc == ref_prime_pc_q && q_ea == ref_prime_ea_q &&
                q_seg == ref_prime_seg_q)
          else $fatal(1, "reference prime did not accompany its exact handoff");
      ref_prime_check_q <= ref_prime_commit && mem_next_ready;
      if (ref_prime_commit && mem_next_ready) begin
        assert (!mem_req && !pipe_int_commit && !fp_shared_mem_admit &&
                !mc_chain_accept && !mc_prime_accept && !mc_valid_q &&
                !tlb_fill_en && !tlb_flush && (gpr_we == '0) && !fp_shared_cmd_valid)
          else $fatal(1, "reference prime created or collided with an owner");
        ref_prime_fp_q <= d_is_x87;
        ref_prime_pc_q <= eip; ref_prime_ea_q <= d_ea; ref_prime_seg_q <= d_seg;
        if (ven_fetchdbg_en)
          $display("[FETCHDBG:REFPRIME] eip=%08x addr=%08x bytes=%0d fp=%0b",
                   eip, mc_query_phys, ref_prime_bytes, d_is_x87);
      end
    end
  end
`endif
`else
  assign ref_prime_select = 1'b0;
  assign ref_prime_offer = 1'b0;
  assign ref_prime_commit = 1'b0;
  assign ref_prime_bytes = 4'd0;
  assign ref_prime_strb = 4'd0;
`endif
