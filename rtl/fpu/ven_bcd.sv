// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/fpu/ven_bcd.sv — ITERATIVE x87 FP -> packed-BCD conversion (FBSTP).
//
// The FPGA-synthesizable, multi-cycle form of the combinational fx_fx_to_bcd
// (fpu_x87_pkg). That function does `for i<18: bcd[i*4+:4]=q%10; q=q/10;` — 18
// CHAINED combinational divide-by-10 stages, which synthesize to a ~182-deep
// CARRY8 cone and were the WHOLE core's worst timing path (fpga/TIMING_PROBLEMS.md
// "Critical-path investigation"), even though FBSTP is a rare instruction.
//
// This engine does the FP->int64 conversion once (fx_to_int_ex, in IDLE) then
// converts the magnitude to BCD by DOUBLE-DABBLE (shift-and-add-3): one binary bit
// per clock, MSB-first, 60 clocks. Each clock every BCD nibble >= 5 gets +3, then
// the BCD register shifts left bringing in the next binary bit. This is pure
// shift+compare+add-3 — NO divide and NO multiply — so it drops the two 64-bit /10
// reciprocal-multiplies the prior digit-extraction synthesized (the bulk of this
// module's LUTs). Slower (~60 vs ~9 clocks) but far more compact; FBSTP is rare.
// Bit-exact to fx_fx_to_bcd (same LSB-first digit layout; correct because the
// |val| >= 1e18 overflow check guarantees 18 digits, so digit 17 never carries out).
// Handshake mirrors ven_idiv / fpu_srt_div; gated into the core behind +VEN_BCD_ITER.
// ===========================================================================
`default_nettype none

module ven_bcd
  import fpu_x87_pkg::*;
(
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,       // 1-clk: begin (ignored if busy)
    input  wire logic [79:0] v,           // ST0 (floatx80)
    input  wire logic [1:0]  rc,          // rounding control (fctrl[11:10])
    output logic             busy,
    output logic             done,        // 1-clk strobe: result valid
    output logic [81:0]      result       // {ie, pe, bcd[79:0]} (== fx_fx_to_bcd)
);
  typedef enum logic [1:0] { ST_IDLE, ST_RUN, ST_FIN, ST_DONE0 } state_t;
  state_t st;

  logic [63:0] q;            // binary magnitude, shifted left MSB-first
  logic [79:0] bcd_acc;      // double-dabble BCD accumulator (18 nibbles in [71:0])
  logic        sign_q, pe_q;
  logic [6:0]  i;            // remaining shift count (60 down to 0)
  logic [81:0] result_q;
  logic        done_q;

  assign busy   = (st != ST_IDLE);
  assign done   = done_q;
  assign result = result_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= ST_IDLE; done_q <= 1'b0;
    end else begin
      done_q <= 1'b0;
      unique case (st)
        ST_IDLE: begin
          if (start) begin
            // FP -> int64 (combinational, mirrors fx_fx_to_bcd's prologue), then
            // |value| and the int64/BCD-range overflow check.
            automatic logic [65:0] ri   = fx_to_int_ex(v, 64, rc);
            automatic logic [63:0] sval = ri[63:0];
            automatic logic [63:0] mag  = sval[63] ? (~sval + 64'd1) : sval;
            if (ri[65] || (mag >= 64'd1000000000000000000)) begin
              // int64-overflow OR |val| >= 10^18 -> packed-BCD indefinite, IE.
              result_q <= {1'b1, 1'b0, 80'hFFFFC000000000000000};
              st <= ST_DONE0;
            end else begin
              sign_q  <= sval[63];
              pe_q    <= ri[64];
              q       <= mag;          // |val| < 1e18 < 2^60
              bcd_acc <= 80'd0;
              i       <= 7'd60;        // 60 double-dabble shifts (bits 59..0)
              st      <= ST_RUN;
            end
          end
        end
        ST_RUN: begin
          // Double-dabble: add-3 every BCD nibble >= 5, then shift the BCD register
          // left by one bringing in the next binary MSB (q[59]). 60 clocks total.
          automatic logic [71:0] corr;
          for (int n = 0; n < 18; n++) begin
            automatic logic [3:0] nib = bcd_acc[n*4 +: 4];
            corr[n*4 +: 4] = (nib >= 4'd5) ? (nib + 4'd3) : nib;
          end
          bcd_acc[71:0] <= {corr[70:0], q[59]};    // shift BCD left, bring in bit 59
          q             <= q << 1;                 // shift binary left (MSB-first)
          i             <= i - 7'd1;
          if (i == 7'd1) st <= ST_FIN;             // 60th (last) shift this clock
        end
        ST_FIN: begin
          // sign byte (0x80 negative / 0x00 positive) in the top byte; flags.
          result_q <= {1'b0, pe_q, {sign_q, 7'd0}, bcd_acc[71:0]};
          done_q   <= 1'b1;
          st       <= ST_IDLE;
        end
        ST_DONE0: begin                            // indefinite path
          done_q <= 1'b1;
          st     <= ST_IDLE;
        end
        default: st <= ST_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
