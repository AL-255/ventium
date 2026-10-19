// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Cache-only successor hint after an unpaired registered U read. Reuse the
// existing saved V descriptor; this bit proves its admission-time byte span
// and remembers intervening invalidation. It is NOT an architectural owner.
logic mc_held_read_prime, mc_fresh_read_prime;
`ifdef VEN_RAW_HELD_READ_PRIME
  logic mc_held_v_valid_q;
  wire [31:0] mc_capture_vlin = flin + {28'd0, u_d.len};
`ifdef VEN_P54_DUAL_LOAD_PAIR
  // A same-line V can retire from the old registered line on this very edge.
  // A next-read hint redirects the lookup and suppresses window_reuse, which
  // would steal that immediate pair. Reserve it using the ACK-independent
  // decoder eligibility, NOT pipe_v_pair_now_accept (cache feedback loop).
  wire mc_fresh_read_pair_block = pipe_pair_mem_ok;
`else
  wire mc_fresh_read_pair_block = 1'b0;
`endif

  always_ff @(posedge clk) begin
    if (!rst_n || exec_flush_all || icsnp_v1 || icsnp_v2 ||
        ic_snoop_valid || ic_snoop_valid1 || ic_snoop_valid2 ||
        tlb_flush || tlb_fill_en || pipe_mem_abort_now ||
        state == S_HALT || state == S_SHUTDOWN) begin
      mc_held_v_valid_q <= 1'b0;
    end else if (!pipe_mem_active_q) begin
      // Same edge on which the existing core captures pipe_mem_v_q. A
      // same-edge successful U needs no saved hint. A later V pair remains
      // excluded by the actual registered owner below, not an early guess.
      mc_held_v_valid_q <= pipe_new_load_req && !def16 && v_bytes_ok &&
          (xlate_miss || fe_xlate_pend || !mem_ack) &&
          !u_d.is_stack && !u_d.is_fp && !u_d.is_branch &&
          !pipe_pair_lookahead && v_d.len != 0 &&
          (mc_capture_vlin[31:12] == flin[31:12]) &&
          ({1'b0, mc_capture_vlin[4:0]} + {2'd0, v_d.len} <= 6'd32) &&
          ({1'b0, eip} + {29'd0, u_d.len} + {29'd0, v_d.len} - 33'd1 <=
           {1'b0, seg_limit[SG_CS]});
    end else if (pipe_int_commit) begin
      mc_held_v_valid_q <= 1'b0;
    end
  end

  assign mc_held_read_prime = mc_held_v_valid_q && (state == S_PIPE) &&
      pipe_mem_active_q && !pipe_mem_we_q && !pipe_mem_pair_q &&
      !pipe_mem_u_q.is_stack && !pipe_mem_u_q.is_fp &&
      !pipe_mem_u_q.is_branch && !mc_valid_q;
  // A read can already have a registered ACK from the preceding hint. Its
  // current V bytes are checked by mc_descriptor, so it needs no saved bit.
  // This offer is ACK-independent; actual U retirement alone commits capture.
  assign mc_fresh_read_prime = !pipe_mem_active_q && !mc_valid_q &&
      pipe_new_load_req && !pipe_pair_lookahead && !mc_fresh_read_pair_block && !u_d.is_stack &&
      !u_d.is_fp && !u_d.is_branch;
`else
  assign mc_held_read_prime = 1'b0;
  assign mc_fresh_read_prime = 1'b0;
`endif
