// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Module-scope optional previous-CLOCK address producer history. Consume the
// existing fully gated writeback authority, never another issue/execute mirror.
// AP-500 241799-002 section 5.2 exempts ONLY implicit PUSH/POP ESP updates:
// CALL/RET/ENTER/LEAVE and other stack bookkeeping remain conservative writers.
// Included only by VEN_P54_AGI_WRITE_MASK; the legacy producer is unchanged
// when the option is absent. Eight FFs replace neither GPRs nor issue ownership.
logic [7:0] p54_prior_write_mask;
logic p54_implicit_esp_update, p54_context_restore_write;
always_comb begin
  p54_implicit_esp_update=1'b0;
  case (state)
    S_PIPE:
      // The owning live/pending packet, not stale slow-path q_* metadata.
      // PUSH/POP are currently NP. If future legal pairing is enabled, never
      // erase a younger V's explicit ESP destination. POP ESP is EXPLICIT.
      p54_implicit_esp_update=pipe_u_eff.is_stack &&
        !(pipe_u_eff.is_load && (pipe_u_eff.dst==R_ESP)) &&
        !(pipe_pair_eff && pipe_v_eff.wreg && (pipe_v_eff.dst==R_ESP));
    S_EXEC, S_STORE:
      // Literal PUSH/POP (including memory/segment forms) use K_ALU. A POP
      // into memory/segment has no explicit ESP register destination even
      // if the decoder's otherwise-irrelevant dst scratch happens to be ESP.
      p54_implicit_esp_update=(q_kind==K_ALU) &&
        (q_is_push ||
         (q_is_pop && (q_mem_write || q_pop_sreg || (q_dst_reg!=R_ESP))));
    default: ;
  endcase
end

// Installing an incoming task/SMM context or rolling back a faulting string
// is not an executed register producer. All other nonwrite/hold/diversion
// clocks naturally erase history because their authoritative gpr_we is zero.
assign p54_context_restore_write=(state==S_TSW_BUSY) || (state==S_RSM);
always_ff @(posedge clk) begin
  if (!rst_n || str_store_rollback_now || p54_context_restore_write)
    p54_prior_write_mask<=8'd0;
  else
    p54_prior_write_mask<=gpr_we & (p54_implicit_esp_update?8'hef:8'hff);
end
