// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// The paid P54 AGI clock has no architectural memory owner. It may lend the
// existing resident-only D-cache port to THIS already decoded U load. The
// normal AGI arm still consumes the full clock and retires nothing.
logic agi_prime_select, agi_prime_offer, agi_prime_commit;
logic [2:0] agi_prime_width;
`ifdef VEN_RAW_AGI_PRIME
`ifndef VEN_RAW_V_READ_PRIME
  initial $fatal(1, "AGI resident prime requires the raw resident port");
`endif
`ifndef VEN_P54_AGI_WRITE_MASK
  initial $fatal(1, "AGI resident prime requires actual prior-clock writers");
`endif
  // No ready/ACK/frontend-valid term may enter this address selection. GPRs
  // already contain the preceding clock's writes; the AGI timing interlock
  // is retained, not used as a reason to read pre-write values.
  assign agi_prime_select = (state == S_PIPE) && cycle_mode && real_bus &&
      pipe_agi && !pipe_mem_active_q && !mc_valid_q &&
      pipe_u_eff.simple && pipe_u_eff.is_mem && !pipe_u_eff.is_store &&
      !pipe_u_eff.is_stack && !pipe_u_eff.is_fp && !pipe_u_eff.is_branch &&
      !pipe_u_eff.w16 && !fp_is_ext_load(pipe_u_eff);
  assign agi_prime_width = fp_mem_source_width(pipe_u_eff);
  assign agi_prime_offer = agi_prime_select && mc_boundary_ok &&
      (agi_prime_width inside {3'd1,3'd4}) &&
      ({1'b0, pipe_load_addr} + ((agi_prime_width == 3'd1) ? 33'd0 : 33'd3)
          <= {1'b0, seg_limit[pipe_mem_seg]}) &&
      ((agi_prime_width == 3'd1) || (mc_query_lin[4:0] <= 5'd28)) &&
      (!paging_on || (mc_lookup_hit && mc_lookup_perm[0] &&
                      ((eff_cpl != 2'd3) || mc_lookup_perm[2])));
  // pipe_fp_live_arm is the shared live-boundary/FSM permit, not an FP-only
  // instruction predicate. fp_sys_bail retains all normal load segment and
  // system-context admission; pending events and cache poison win as usual.
  assign agi_prime_commit = agi_prime_offer && pipe_fp_live_arm &&
      !fp_sys_bail && !pipe_fetch_checked_handoff &&
      !rep_stos_cont_recovery_need && !rep_stos_cont_take &&
      !icsnp_v1 && !icsnp_v2 && !ic_snoop_valid2
`ifdef VEN_FP_PIPE
      && !fp_pipe_rd_haz
`endif
      ;
`ifndef SYNTHESIS
  logic agi_prime_check_q;
  logic [31:0] agi_prime_pc_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      agi_prime_check_q <= 1'b0; agi_prime_pc_q <= 0;
    end else begin
      if (agi_prime_check_q)
        assert (state == S_PIPE && eip == agi_prime_pc_q && !pipe_mem_active_q)
          else $fatal(1, "AGI resident prime skipped its paid no-issue clock");
      agi_prime_check_q <= agi_prime_commit && mem_next_ready;
      if (agi_prime_commit && mem_next_ready) begin
        assert (pipe_agi && !mem_req && !pipe_int_commit && !pipe_new_mem_req &&
                !mc_chain_accept && !mc_prime_accept && !ref_prime_commit &&
                !tlb_fill_en && !tlb_flush && (gpr_we == '0) && !fp_shared_cmd_valid)
          else $fatal(1, "AGI resident prime created or collided with an owner");
        agi_prime_pc_q <= eip;
        if (ven_fetchdbg_en)
          $display("[FETCHDBG:AGIPRIME] eip=%08x addr=%08x bytes=%0d",
                   eip, mc_query_phys, agi_prime_width);
      end
    end
  end
`endif
`else
  assign agi_prime_select = 1'b0;
  assign agi_prime_offer = 1'b0;
  assign agi_prime_commit = 1'b0;
  assign agi_prime_width = 3'd0;
`endif
