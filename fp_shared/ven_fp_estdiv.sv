// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Area/timing-oriented estimateDiv128To64 service.  It preserves the exact
// operation ordering of fpu_estdiv, but the two bounded 64/32 quotients share
// one 32-cycle restoring divider instead of inferring two single-cycle divide
// cones.  Callers already use a req/vld contract, so only latency changes.
`default_nettype none

module ven_fp_estdiv (
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        req,
    input  wire logic [63:0] a0,
    input  wire logic [63:0] a1,
    input  wire logic [63:0] b,
    output logic             vld,
    output logic [63:0]      z
);
  typedef enum logic [2:0] {
    E_IDLE, E_D1, E_DIV, E_MUL, E_CORR, E_D2
  } est_t;
  est_t est_q;

  logic [63:0] a0_q, a1_q, b_q, z_q, rem0_q, rem1_q;
  logic [31:0] b0_q;
  logic [2:0]  correction_q;

  // One physical divider is reused for both quotient fields.  The prechecks
  // guarantee dividend/divisor < 2^32, so the high dividend word is a valid
  // initial remainder and exactly 32 quotient iterations are sufficient.
  logic        div_second_q;
  logic [31:0] div_den_q, div_lo_q, div_quot_q;
  logic [32:0] div_rem_q;
  logic [5:0]  div_count_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      est_q        <= E_IDLE;
      vld          <= 1'b0;
      z            <= 64'd0;
      a0_q         <= 64'd0;
      a1_q         <= 64'd0;
      b_q          <= 64'd0;
      b0_q         <= 32'd0;
      z_q          <= 64'd0;
      rem0_q       <= 64'd0;
      rem1_q       <= 64'd0;
      correction_q <= 3'd0;
      div_second_q <= 1'b0;
      div_den_q    <= 32'd0;
      div_lo_q     <= 32'd0;
      div_quot_q   <= 32'd0;
      div_rem_q    <= 33'd0;
      div_count_q  <= 6'd0;
    end else begin
      vld <= 1'b0;
      unique case (est_q)
        E_IDLE: begin
          if (req) begin
            if (b <= a0) begin
              z   <= 64'hffffffffffffffff;
              vld <= 1'b1;
            end else begin
              a0_q  <= a0;
              a1_q  <= a1;
              b_q   <= b;
              b0_q  <= b[63:32];
              est_q <= E_D1;
            end
          end
        end

        // First quotient is either the specified saturation value or a
        // bounded 32-bit a0/b0 result placed in the high word.
        E_D1: begin
          if ({b0_q, 32'd0} <= a0_q) begin
            z_q   <= 64'hffffffff00000000;
            est_q <= E_MUL;
          end else begin
            div_second_q <= 1'b0;
            div_den_q    <= b0_q;
            div_lo_q     <= a0_q[31:0];
            div_quot_q   <= 32'd0;
            div_rem_q    <= {1'b0, a0_q[63:32]};
            div_count_q  <= 6'd0;
            est_q        <= E_DIV;
          end
        end

        // One quotient digit per cycle: 33-bit compare/subtract replaces the
        // 574-CARRY8 single-cycle divider seen in the baseline OOC report.
        E_DIV: begin
          automatic logic [32:0] shifted_rem;
          automatic logic [32:0] next_rem;
          automatic logic [31:0] next_quot;
          shifted_rem = {div_rem_q[31:0], div_lo_q[31]};
          if (shifted_rem >= {1'b0, div_den_q}) begin
            next_rem  = shifted_rem - {1'b0, div_den_q};
            next_quot = {div_quot_q[30:0], 1'b1};
          end else begin
            next_rem  = shifted_rem;
            next_quot = {div_quot_q[30:0], 1'b0};
          end
          div_rem_q  <= next_rem;
          div_lo_q   <= {div_lo_q[30:0], 1'b0};
          div_quot_q <= next_quot;
          if (div_count_q == 6'd31) begin
            if (div_second_q) begin
              z     <= z_q | {32'd0, next_quot};
              vld   <= 1'b1;
              est_q <= E_IDLE;
            end else begin
              z_q   <= {next_quot, 32'd0};
              est_q <= E_MUL;
            end
          end else begin
            div_count_q <= div_count_q + 6'd1;
          end
        end

        // t=b*z; rem={a0,a1}-t.  This registered multiply stage is retained
        // verbatim from the proven estimator.
        E_MUL: begin
          automatic logic [127:0] t128;
          automatic logic [127:0] rem128;
          t128   = {64'd0, b_q} * {64'd0, z_q};
          rem128 = {a0_q, a1_q} - t128;
          rem0_q       <= rem128[127:64];
          rem1_q       <= rem128[63:0];
          correction_q <= 3'd0;
          est_q        <= E_CORR;
        end

        E_CORR: begin
          if (rem0_q[63] && (correction_q != 3'd6)) begin
            automatic logic [127:0] rem128;
            rem128 = {rem0_q, rem1_q} + {{32'd0, b0_q}, b_q << 32};
            z_q          <= z_q - 64'h0000000100000000;
            rem0_q       <= rem128[127:64];
            rem1_q       <= rem128[63:0];
            correction_q <= correction_q + 3'd1;
          end else begin
            est_q <= E_D2;
          end
        end

        // The second quotient reuses the same divider and fills z[31:0].
        E_D2: begin
          automatic logic [63:0] r0;
          r0 = (rem0_q << 32) | (rem1_q >> 32);
          if ({b0_q, 32'd0} <= r0) begin
            z     <= z_q | 64'h00000000ffffffff;
            vld   <= 1'b1;
            est_q <= E_IDLE;
          end else begin
            div_second_q <= 1'b1;
            div_den_q    <= b0_q;
            div_lo_q     <= r0[31:0];
            div_quot_q   <= 32'd0;
            div_rem_q    <= {1'b0, r0[63:32]};
            div_count_q  <= 6'd0;
            est_q        <= E_DIV;
          end
        end

        default: est_q <= E_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
