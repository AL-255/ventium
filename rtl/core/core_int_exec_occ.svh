// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Module-scope execution hold, included by core.sv and its focused unit test.
// Intel Pentium manual Vol.3 Appendix F, Table F-2 specifies these cache-hit
// clocks; Vol.1 3.1.1 places data-cache reads in EX, not in instruction fetch.
// A completed source read consumes ONE of the EX clocks. Cache/page/fragment
// waits and all frontend work are additional, never occupancy credits.
logic p54_int_exec_hold;
logic fsm_case_ready;
`ifdef VEN_P54_INT_EXEC_OCC
logic p54_int_exec_active_q;
logic [5:0] p54_int_exec_rem_q;
logic [5:0] p54_int_exec_wait;
logic p54_int_exec_candidate;

always_comb begin
  logic [5:0] target, datapath_clocks;
  target=6'd0;
  datapath_clocks=6'd1; // native result/flags commit occupies the final EX edge
  if (q_kind==K_IMUL2) target=6'd10;
  else if (q_kind==K_EXT) target=6'd3;
  // Normal rotates and shifts by CL are four-clock NP. Carry rotates are
  // different (RCL/RCR: 7..24 register clocks), not a four-clock shortcut.
  else if (q_kind==K_SHIFT && q_shift_cl &&
           (q_shrot inside {3'd0,3'd1,3'd4,3'd5,3'd6,3'd7})) target=6'd4;
  else if (q_kind==K_MULDIV) begin
    case (q_md)
      3'd4,3'd5: target=(q_w==3'd4) ? 6'd10 : 6'd11;
      3'd6: target=(q_w==3'd4) ? 6'd41 : (q_w==3'd2) ? 6'd25 : 6'd17;
      3'd7: target=(q_w==3'd4) ? 6'd46 : (q_w==3'd2) ? 6'd30 : 6'd22;
      default: ;
    endcase
`ifdef VEN_IDIV_ITER
    // ven_idiv: S_EXEC start, nbits/2 RUN edges, FIN, core done consumption.
    // All are actual EX clocks. Hold BEFORE start; never lose a one-edge done
    // pulse or apply the legacy post-retire residual on top of the engine.
    if (q_md==3'd6 || q_md==3'd7)
      datapath_clocks=(q_w==3'd4) ? 6'd35 : (q_w==3'd2) ? 6'd19 : 6'd11;
`endif
  end
  if (q_mem_read) datapath_clocks=datapath_clocks+6'd1;
  p54_int_exec_wait=(target>datapath_clocks) ? target-datapath_clocks : 6'd0;
  p54_int_exec_candidate=cycle_mode && (state==S_EXEC) && (target!=6'd0);
end

// For N held edges, load N-1 on the first edge and decrement thereafter.
// Thus native target10 has nine no-commit edges followed by one commit edge.
// Shared fsm_case_ready stops the countdown on a higher-priority diversion;
// fsm_case_enabled also consumes this hold, fencing the separate GPR mirror.
assign p54_int_exec_hold=p54_int_exec_candidate && (p54_int_exec_wait!=6'd0) &&
                         (!p54_int_exec_active_q || p54_int_exec_rem_q!=6'd0);
always_ff @(posedge clk) begin
  if (!rst_n || !p54_int_exec_candidate
`ifdef VEN_P54_PREFIX_EX_CHAIN
      // The final old EX edge installs a new operation without leaving
      // S_EXEC. Its countdown must not inherit the old owner's zero.
      || p54_prefix_ex_take
`endif
     ) begin
    p54_int_exec_active_q<=1'b0;
    p54_int_exec_rem_q<=6'd0;
  end else if (fsm_case_ready) begin
    if (!p54_int_exec_active_q) begin
      p54_int_exec_active_q<=1'b1;
      p54_int_exec_rem_q<=(p54_int_exec_wait==6'd0) ? 6'd0 : p54_int_exec_wait-6'd1;
    end else if (p54_int_exec_rem_q!=6'd0)
      p54_int_exec_rem_q<=p54_int_exec_rem_q-6'd1;
  end
end
`else
assign p54_int_exec_hold=1'b0;
`endif
