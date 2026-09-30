// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Raw U decode only: one existing combinational decoder, no retained uop.
// Select inputs solely from opcode/default width, never cache/issue permits.
logic p54_prefix66_shift, p54_prefix66_shape, p54_prefix66_candidate;
logic [7:0] p54_prefix66_db [7];
fpd_t p54_prefix66_base;
assign p54_prefix66_shift=!def16 && (ub[0]==8'h66);
always_comb begin
  for (int i=0;i<7;i++) begin
    p54_prefix66_db[i]=ub[i];
    if (p54_prefix66_shift) begin
      if (i<6) p54_prefix66_db[i]=ub[i+1];
      else p54_prefix66_db[i]=8'd0;
    end
  end
end
decode u_decode (
  .ib0(p54_prefix66_db[0]),.ib1(p54_prefix66_db[1]),
  .ib2(p54_prefix66_db[2]),.ib3(p54_prefix66_db[3]),
  .ib4(p54_prefix66_db[4]),.ib5(p54_prefix66_db[5]),
  .ib6(p54_prefix66_db[6]),.iflags(eflags),
  .def16(def16 || p54_prefix66_shift),.cycle_mode(cycle_mode),
  .uop(p54_prefix66_base)
);
always_comb begin
  // Only documented UV/PU register forms. No prefix+0F/byte/memory/LEA,
  // stack, FP, branch, CL shift, carry rotate or multiple prefix grammar.
  p54_prefix66_shape=1'b0;
  unique casez (ub[1])
    8'b1011_1???,8'b0100_????,
    8'h05,8'h0d,8'h15,8'h1d,8'h25,8'h2d,8'h35,8'h3d,8'ha9:
      p54_prefix66_shape=1'b1;
    8'h01,8'h03,8'h09,8'h0b,8'h11,8'h13,8'h19,8'h1b,
    8'h21,8'h23,8'h29,8'h2b,8'h31,8'h33,8'h39,8'h3b,
    8'h81,8'h83,8'h85,8'h89,8'h8b:
      p54_prefix66_shape=(ub[2][7:6]==2'b11);
    8'hc7:
      p54_prefix66_shape=(ub[2][7:6]==2'b11) && (ub[2][5:3]==3'd0);
    8'hc1,8'hd1:
      p54_prefix66_shape=(ub[2][7:6]==2'b11) && ub[2][5];
    default: ;
  endcase
  p54_prefix66_candidate=p54_prefix66_shift && p54_prefix66_shape &&
      cycle_mode && p54_prefix66_context_ok &&
      // These are registered older owners, not request/ACK/flush cones. A
      // new prefix must not be exposed as simple while its paid-D1 live
      // contract is disabled (ordinary INT may overlap asynchronous FP).
      !pipe_mem_active_q && !fp_async_pending && !fp_occ_pending &&
      !xp_pend && !xs_act && !fx_act && p54_prefix66_base.simple &&
      p54_prefix66_base.pairs_first && !p54_prefix66_base.w8 &&
      !p54_prefix66_base.is_mem && !p54_prefix66_base.is_store &&
      !p54_prefix66_base.is_stack && !p54_prefix66_base.is_lea &&
      !p54_prefix66_base.is_branch && !p54_prefix66_base.is_fp &&
      !p54_prefix66_base.shift_cl && (p54_prefix66_base.len<=4'd4);
  u_d=p54_prefix66_base;
  if (p54_prefix66_shift) begin
    if (p54_prefix66_candidate) begin
      u_d.len=p54_prefix66_base.len+4'd1;
      u_d.pairs_first=1'b1;
      u_d.pairs_second=1'b0; // AP-5005.5: prefixed UV/PU is PU, never V.
    end else begin
      u_d='{default:'0};
      u_d.alu_op=ALU_ADD;
      u_d.len=4'd1;
      u_d.w16=def16;
    end
  end
end
