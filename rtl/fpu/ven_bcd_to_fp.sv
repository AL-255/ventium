// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/fpu/ven_bcd_to_fp.sv — ITERATIVE x87 packed-BCD -> floatx80 (FBLD).
//
// The FPGA-synthesizable, multi-cycle form of the combinational fx_bcd_to_fx
// (fpu_x87_pkg). That function does `for i=17..0: mag = mag*10 + digit[i]` — 18
// CHAINED combinational multiply-by-10 stages, a ~189-deep CARRY8 cone that
// became the core's worst LOGIC path once the FP arith was pipelined
// (+VEN_FP_PIPE), even though FBLD is a rare instruction (the load-side twin of
// FBSTP / ven_bcd).
//
// This engine accumulates the 18 BCD digits MSD-first, TWO *10 steps per clock
// (~9 clocks), so the per-clock path is one or two *10 stages instead of 18
// chained; the int64 -> floatx80 conversion (fx_from_int, exact: 18 digits <
// 1e18 < 2^63) happens once in FIN. Bit-exact to fx_bcd_to_fx. Handshake mirrors
// ven_bcd; gated into the core behind +VEN_BCD_ITER.
// ===========================================================================
`default_nettype none

module ven_bcd_to_fp
  import fpu_x87_pkg::*;
(
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,       // 1-clk: begin (ignored if busy)
    input  wire logic [79:0] bcd,         // packed-BCD m80 (byte9 bit7 = sign)
    output logic             busy,
    output logic             done,        // 1-clk strobe: result valid
    output logic [79:0]      result       // floatx80 (== fx_bcd_to_fx)
);
  typedef enum logic [1:0] { ST_IDLE, ST_RUN, ST_FIN } state_t;
  state_t st;

  logic [63:0] mag;
  logic        sign_q;
  logic [4:0]  idx;       // next digit pair's HIGH index (17,15,...,1), MSD-first
  logic [79:0] bcd_q;
  logic [79:0] result_q;
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
            mag    <= 64'd0;
            sign_q <= bcd[79];      // byte9 bit7
            bcd_q  <= bcd;
            idx    <= 5'd17;
            st     <= ST_RUN;
          end
        end
        ST_RUN: begin
          // two digits per clock, MOST-significant first: mag = mag*10 + d_hi,
          // then *10 + d_lo. Two chained *10 (mirrors ven_bcd's two /10), so the
          // per-clock path is bounded regardless of the 18-digit length.
          automatic logic [3:0] da = bcd_q[{idx,         2'b00} +: 4];   // digit idx
          automatic logic [3:0] db = bcd_q[{(idx-5'd1),  2'b00} +: 4];   // digit idx-1
          mag <= (mag*64'd10 + {60'd0, da})*64'd10 + {60'd0, db};
          idx <= idx - 5'd2;
          if (idx == 5'd1) st <= ST_FIN;            // just consumed digits 1 and 0
        end
        ST_FIN: begin
          automatic logic signed [63:0] sval = sign_q ? -$signed(mag) : $signed(mag);
          result_q <= fx_from_int(sval);
          done_q   <= 1'b1;
          st       <= ST_IDLE;
        end
        default: st <= ST_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
