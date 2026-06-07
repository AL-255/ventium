// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/fpu/fpu_srt_div.sv — ITERATIVE radix-4 SRT floating-point divider.
//
// This is the multi-cycle, one-radix-4-step-per-clock hardware form of the
// combinational fpu_x87_pkg::fx_srt_div (the genuine Pentium SRT divider). The
// per-step carry-save recurrence and the final remainder-sign-tiebreak rounding
// are lifted VERBATIM from fx_srt_div so the committed floatx80 is bit-identical
// to it (and therefore to tools/srt/srt_model.py and QEMU). The point of the
// rewrite: the combinational version unrolls all 36 radix-4 steps into one giant
// cone (~126 256-bit adders in synth — see fpga/TIMING_PROBLEMS.md P0-1); this
// version executes ONE step per clock, collapsing that area and the critical path.
//
// FDIV-bug fidelity is preserved: `buggy` selects the buggy quotient-selection
// PLA (the 5 missing +2 cells) exactly as fx_srt_div does, so the documented
// flaw still EMERGES from the datapath (not special-cased).
//
// Handshake: pulse `start` (with a/b/rc/buggy stable) when !busy. The engine
// raises `busy`, runs, then pulses `done` for one clock with `result` valid
// ({inexact, floatx80}). Special operands (divide-by-zero, zero dividend) are
// resolved in one extra clock, mirroring fx_srt_div's own guards.
// ===========================================================================
`default_nettype none

module fpu_srt_div
  import fpu_x87_pkg::*;
(
    input  wire logic        clk,
    input  wire logic        rst_n,      // active-low synchronous reset
    input  wire logic        start,      // 1-clk: begin a divide (ignored if busy)
    input  wire logic [79:0] a,          // dividend  (floatx80)
    input  wire logic [79:0] b,          // divisor   (floatx80)
    input  wire logic [1:0]  rc,         // x87 rounding control (fctrl[11:10])
    input  wire logic        buggy,      // 1 = buggy PLA (reproduce the FDIV flaw)
    output logic             busy,       // 1 while a divide is in flight
    output logic             done,       // 1-clk strobe: result valid this clock
    output logic [80:0]      result      // {inexact, floatx80}
);
  localparam int NSTEP = 36;             // == fx_srt_div NSTEP (72 quotient bits)

  typedef enum logic [1:0] { ST_IDLE, ST_RUN, ST_FIN, ST_SPECIAL } state_t;
  state_t st;

  // ---- latched operand-derived constants (set at start) --------------------
  logic                sign;
  logic signed [31:0]  ua, ub;
  logic [3:0]          d4;
  logic [79:0]         dfx;              // divisor significand * 2^72

  // ---- iteration state (registered across clocks) --------------------------
  logic [79:0]         S, C;             // carry-save partial remainder
  logic signed [127:0] qacc;             // quotient accumulator
  logic [6:0]          k;                // step counter 0..NSTEP

  // ---- result register -----------------------------------------------------
  logic [80:0]         result_q;
  logic                done_q;

  assign busy   = (st != ST_IDLE);
  assign done   = done_q;
  assign result = result_q;

  // ==========================================================================
  // Combinational per-step body — IDENTICAL to fx_srt_div lines 386-411.
  // ==========================================================================
  logic [6:0]          psum;
  logic signed [6:0]   P_idx;
  logic signed [2:0]   q;
  logic signed [127:0] qext;
  logic [79:0]         T, sxor, cmaj;
  logic                cf;
  always_comb begin
    psum  = S[75:69] + C[75:69];
    P_idx = $signed(psum);
    q     = fx_srt_pla(P_idx, d4, buggy);
    qext  = q;                            // sign-extend 3-bit signed -> 128
    cf    = (q > 0);
    unique case (q)
      3'sd2:   T = ~(dfx << 1);
      3'sd1:   T = ~dfx;
      3'sd0:   T = 80'd0;
      -3'sd1:  T = dfx;
      -3'sd2:  T = dfx << 1;
      default: T = 80'd0;
    endcase
    sxor = S ^ C ^ T;
    cmaj = ((S & C) | (S & T) | (C & T)) << 1;
    if (cf) cmaj[0] = 1'b1;
  end

  // ==========================================================================
  // Combinational rounding tail — IDENTICAL to fx_srt_div lines 414-443. Uses
  // the registered final qacc/S/C; evaluated in ST_FIN.
  // ==========================================================================
  logic [80:0]         rsum;
  logic                rem_neg, rem_nz, rs_pos, rs_neg, up, inexact;
  logic [127:0]        uq, keep, remv, half;
  int                  msb, extra;
  logic signed [31:0]  e, ebiased;
  always_comb begin
    rsum    = {1'b0, C} + {1'b0, S};
    rem_neg = rsum[79];
    rem_nz  = (rsum[79:0] != 80'd0);
    rs_neg  = rem_neg;
    rs_pos  = !rem_neg && rem_nz;
    uq      = qacc;                       // positive for normal operands
    msb     = 0;
    for (int i=127; i>=0; i--) if (uq[i]) begin msb=i; break; end
    extra   = msb - 63;
    keep    = uq >> extra;
    remv    = uq & ((128'd1 << extra) - 128'd1);
    half    = 128'd1 << (extra-1);
    inexact = (remv != 128'd0) || rs_pos || rs_neg;
    unique case (rc)
      2'd0:
        if      (remv > half) up = 1'b1;
        else if (remv < half) up = 1'b0;
        else                  up = rs_pos ? 1'b1 : (rs_neg ? 1'b0 : keep[0]);
      2'd1:    up = inexact &&  sign;
      2'd2:    up = inexact && !sign;
      default: up = 1'b0;
    endcase
    if (up) begin
      keep = keep + 128'd1;
      if (keep[64]) begin keep = keep >> 1; msb = msb + 1; end
    end
    e       = (msb - 70) + (ua - ub);
    ebiased = e + 32'sd16383;
  end

  // ==========================================================================
  // Sequencer
  // ==========================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= ST_IDLE; done_q <= 1'b0; k <= '0;
    end else begin
      done_q <= 1'b0;                     // default: pulse low
      unique case (st)
        ST_IDLE: begin
          if (start) begin
            // latch sign + operand fields (mirror fx_srt_div lines 374-384)
            sign <= fx_sign(a) ^ fx_sign(b);
            if (fx_is_zero(b)) begin
              // div-by-zero -> signed Inf
              result_q <= {1'b0, fx_make(fx_sign(a) ^ fx_sign(b), 15'h7fff,
                                         64'h8000000000000000)};
              st <= ST_SPECIAL;
            end else if (fx_is_zero(a)) begin
              // zero dividend -> signed zero
              result_q <= {1'b0, fx_make(fx_sign(a) ^ fx_sign(b), 15'd0, 64'd0)};
              st <= ST_SPECIAL;
            end else begin
              // bind mantissas to temps (IEEE 1800 forbids a bit-select on a
              // function-call result; Vivado synth enforces it).
              automatic logic [63:0] ma_ = fx_man(a);
              automatic logic [63:0] mb_ = fx_man(b);
              ua   <= fx_uexp(a);
              ub   <= fx_uexp(b);
              d4   <= mb_[62:59];
              dfx  <= {7'b0, mb_, 9'b0};
              S    <= {7'b0, ma_, 9'b0};
              C    <= 80'd0;
              qacc <= 128'sd0;
              k    <= '0;
              st   <= ST_RUN;
            end
          end
        end
        ST_RUN: begin
          // one radix-4 step: accumulate digit, advance carry-save remainder
          qacc <= qacc + (qext <<< (70 - 2*int'(k)));
          S    <= sxor << 2;
          C    <= cmaj << 2;
          if (k == NSTEP-1) st <= ST_FIN;
          k    <= k + 7'd1;
        end
        ST_FIN: begin
          result_q <= {inexact, fx_make(sign, ebiased[14:0], keep[63:0])};
          done_q   <= 1'b1;
          st       <= ST_IDLE;
        end
        ST_SPECIAL: begin
          done_q <= 1'b1;                 // result_q already latched in ST_IDLE
          st     <= ST_IDLE;
        end
        default: st <= ST_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
