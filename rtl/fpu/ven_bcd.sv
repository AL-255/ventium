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
// extracts the 18 BCD digits two /10 steps per clock (~9 clocks), so the per-clock
// path is one or two /10 stages instead of 18 chained. Bit-exact to fx_fx_to_bcd.
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

  logic [63:0] q;
  logic [79:0] bcd_acc;
  logic        sign_q, pe_q;
  logic [4:0]  i;
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
              q       <= mag;
              bcd_acc <= 80'd0;
              i       <= 5'd0;
              st      <= ST_RUN;
            end
          end
        end
        ST_RUN: begin
          // two BCD-digit extractions per clock (digit i at bit i*4, LSB-first).
          automatic logic [3:0]  d0 = q[3:0]  ; // placeholder, recomputed below
          automatic logic [63:0] q1;
          automatic logic [3:0]  d1;
          automatic logic [63:0] q2;
          d0 = q  % 64'd10;  q1 = q  / 64'd10;
          d1 = q1 % 64'd10;  q2 = q1 / 64'd10;
          bcd_acc[{i,        2'b00} +: 4] <= d0;   // digit i
          bcd_acc[{(i+5'd1), 2'b00} +: 4] <= d1;   // digit i+1
          q <= q2;
          i <= i + 5'd2;
          if (i >= 5'd16) st <= ST_FIN;            // just did digits 16,17
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
