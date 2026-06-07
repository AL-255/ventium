// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/core/ven_idiv.sv — ITERATIVE integer DIV/IDIV engine.
//
// The FPGA-synthesizable, multi-cycle form of the combinational native '/' and
// '%' used by core_exec.svh's K_MULDIV DIV/IDIV arms (which synthesize to a
// ~585-deep CARRY8 restoring-divide cone — see fpga/TIMING_PROBLEMS.md P0-2).
// Restoring division on MAGNITUDES (2 radix-2 steps/clock) + x86 sign fix-up
// (quotient sign = dividend^divisor, remainder sign = dividend; truncate toward
// zero, matching SystemVerilog signed '/'/'%'); divide-error (#DE) on a zero
// divisor or a quotient that overflows the destination width, using the EXACT
// per-width predicates from core_exec.svh so it is bit-exact to the native path.
//
// Handshake mirrors fpu_srt_div: pulse `start` (operands stable) when !busy;
// the engine raises `busy`, then pulses `done` for one clock with quotient /
// remainder / derr valid. Gated into the core behind +VEN_IDIV_ITER.
// ===========================================================================
`default_nettype none

module ven_idiv (
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,       // 1-clk: begin (ignored if busy)
    input  wire logic        is_signed,   // 1 = IDIV (signed), 0 = DIV (unsigned)
    input  wire logic [2:0]  w,           // operand width: 1=r/m8, 2=r/m16, 4=r/m32
    input  wire logic [63:0] dividend,    // AX / {DX,AX} / {EDX,EAX} (low nbits used)
    input  wire logic [31:0] divisor,     // divisor (low wbits used)
    output logic             busy,
    output logic             done,        // 1-clk strobe: result valid
    output logic [31:0]      quotient,    // low bits per width (writeback slices)
    output logic [31:0]      remainder,
    output logic             derr         // divide error (#DE): /0 or overflow
);
  typedef enum logic [1:0] { ST_IDLE, ST_RUN, ST_FIN, ST_DONE0 } state_t;
  state_t st;

  // latched per-op
  logic        s_signed;
  logic [2:0]  s_w;
  logic        q_neg, r_neg;
  logic [31:0] mag_dvr;                   // |divisor|
  logic [63:0] q_reg;                     // dividend (left-aligned) -> quotient magnitude
  logic [32:0] p_reg;                     // running remainder (magnitude)
  logic [6:0]  cnt;                       // dividend bits remaining (nbits..0, step by 2)
  logic        zero_derr;                 // divisor==0 captured at start

  logic [31:0] quot_q, rem_q;
  logic        derr_q, done_q;

  assign busy      = (st != ST_IDLE);
  assign done      = done_q;
  assign quotient  = quot_q;
  assign remainder = rem_q;
  assign derr      = derr_q;

  // width helpers (combinational on the latched width)
  function automatic int unsigned nbits_of(input logic [2:0] ww);
    nbits_of = (ww==3'd1) ? 16 : (ww==3'd2) ? 32 : 64;
  endfunction
  function automatic int unsigned wbits_of(input logic [2:0] ww);
    wbits_of = (ww==3'd1) ? 8 : (ww==3'd2) ? 16 : 32;
  endfunction

  // ---- one radix-2 restoring step (shift {p,q} left, trial-subtract) -------
  // chained twice per clock in ST_RUN.
  function automatic void rstep(inout logic [32:0] p, inout logic [63:0] q,
                                input logic [31:0] dvr);
    logic [32:0] psh;
    logic        ge;
    psh = {p[31:0], q[63]};
    ge  = (psh >= {1'b0, dvr});
    p   = ge ? (psh - {1'b0, dvr}) : psh;
    q   = {q[62:0], ge};
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= ST_IDLE; done_q <= 1'b0;
    end else begin
      done_q <= 1'b0;
      unique case (st)
        ST_IDLE: begin
          if (start) begin
            automatic int unsigned nb = nbits_of(w);
            automatic int unsigned wb = wbits_of(w);
            automatic logic        dvd_neg = is_signed & dividend[nb-1];
            automatic logic        dvr_neg = is_signed & divisor[wb-1];
            automatic logic [63:0] ndvd = dividend & ((nb==64) ? 64'hFFFFFFFFFFFFFFFF : ((64'd1<<nb)-64'd1));
            automatic logic [31:0] ndvr = divisor  & ((32'd1<<wb)-32'd1);
            automatic logic [63:0] mdvd = dvd_neg ? ((~ndvd + 64'd1) & ((nb==64) ? 64'hFFFFFFFFFFFFFFFF : ((64'd1<<nb)-64'd1))) : ndvd;
            automatic logic [31:0] mdvr = dvr_neg ? ((~ndvr + 32'd1) & ((32'd1<<wb)-32'd1)) : ndvr;
            s_signed <= is_signed; s_w <= w;
            q_neg    <= is_signed & (dvd_neg ^ dvr_neg);
            r_neg    <= dvd_neg;                 // remainder takes the dividend sign
            if (ndvr == 32'd0) begin
              zero_derr <= 1'b1;
              st <= ST_DONE0;
            end else begin
              zero_derr <= 1'b0;
              mag_dvr <= mdvr;
              q_reg   <= mdvd << (64 - nb);      // left-align: MSB at bit 63
              p_reg   <= 33'd0;
              cnt     <= nb[6:0];
              st      <= ST_RUN;
            end
          end
        end
        ST_RUN: begin
          // two restoring steps per clock
          automatic logic [32:0] p = p_reg;
          automatic logic [63:0] q = q_reg;
          rstep(p, q, mag_dvr);
          rstep(p, q, mag_dvr);
          p_reg <= p; q_reg <= q;
          if (cnt <= 7'd2) st <= ST_FIN;
          cnt <= cnt - 7'd2;
        end
        ST_FIN: begin
          // quotient magnitude (mask to nbits for r8/r16; whole reg for r32),
          // remainder magnitude; apply x86 signs; native per-width overflow #DE.
          automatic int unsigned nb = nbits_of(s_w);
          automatic logic [63:0] qmag = (s_w==3'd4) ? q_reg : (q_reg & ((64'd1<<nb)-64'd1));
          automatic logic [63:0] rmag = {31'd0, p_reg};
          automatic logic [63:0] qs   = q_neg ? (~qmag + 64'd1) : qmag;
          automatic logic [63:0] rs   = r_neg ? (~rmag + 64'd1) : rmag;
          automatic logic        ov;
          unique case (s_w)
            3'd1: ov = s_signed ? (qs[15:0] != {{8{qs[7]}},  qs[7:0]})  : (qmag[15:8] != 8'd0);
            3'd2: ov = s_signed ? (qs[31:0] != {{16{qs[15]}},qs[15:0]}) : (qmag[31:16]!= 16'd0);
            default: ov = s_signed ? (qs[63:0] != {{32{qs[31]}},qs[31:0]}) : (qmag[63:32]!= 32'd0);
          endcase
          quot_q <= qs[31:0];
          rem_q  <= rs[31:0];
          derr_q <= ov;
          done_q <= 1'b1;
          st     <= ST_IDLE;
        end
        ST_DONE0: begin                    // divide-by-zero: derr, no result
          quot_q <= 32'd0; rem_q <= 32'd0; derr_q <= 1'b1;
          done_q <= 1'b1;
          st     <= ST_IDLE;
        end
        default: st <= ST_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
