// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/fpu/fpu_fx_ppl.sv — SHARED, PIPELINED floatx80 add/mul ALU (#11 perf).
//
// WHY. The iterative transcendental engines (fpu_fsincos / fpu_fyl2x /
// fpu_f2xm1 / fpu_fpatan) evaluated their polynomials by calling the
// COMBINATIONAL fx_mul / fx_add inline, often CHAINED — e.g. fpu_fsincos's
// Horner step was
//     sp <= fx80(fx_add(fx80(fx_mul(sp, r2, ...)), sinc(idx), ...));
// i.e. a full 64x64 multiply + normalize + round-and-pack FOLLOWED BY an align
// + add + normalize + round-and-pack, ALL IN ONE CLOCK — and duplicated for the
// parallel sin/cos chains. That was the design's fmax bottleneck (it forced the
// ~6 MHz core clock: the routed worst path was ~167 ns) and, replicated across
// four engines, a large slice of the area (the all-transcendental build missed
// placement by ~175 CLBs).
//
// WHAT. ONE 2-stage pipeline of the SAME arithmetic, reusing the
// already-verified split primitives from fpu_x87_pkg:
//   stage 1  fx_mul_s1 / fx_add_s1   -> fx_pipe_t (unpack/align/multiply + msb)
//   stage 2  fx_round_pack_f         -> the rounded floatx80
// Sequencing an engine's ops through this ALU means at most ONE of those two
// stages sits in any clock, and the four parallel per-engine op instances
// collapse into a single shared datapath.
//
// BIT-EXACTNESS. fx_mul/fx_add ARE literally their s1 front followed by
// fx_round_pack_f (fpu_x87_pkg lines 319/323/361/389), including the four
// `early` special cases (+-0 + -+0, a==0, b==0, exact cancellation). So
//     y == fx80(fx_mul(a,b,rc,pc))   /   fx80(fx_add(a,b,rc,pc))
// bit-for-bit; the verif/trsc per-engine gates stay valid unchanged and only
// the cycle count grows (irrelevant: transcendentals are rare instructions,
// and they get a far faster clock in exchange).
//
// HANDSHAKE. Pulse `req` for one clock with {op,a,b,rc,pc}; `vld` pulses two
// clocks later with {y,pe}. The engines run strictly one-at-a-time (the core
// sits in S_TRSC_BUSY for exactly one op), so one shared instance never
// contends. Not pipelined back-to-back by design: issue the next `req` after
// `vld` (the engines are sequential anyway).
// ===========================================================================
`default_nettype none

(* use_dsp = "yes" *)   // the 64x64 significand multiply -> DSP48
module fpu_fx_ppl
  import fpu_x87_pkg::*;
(
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        req,        // 1-clk pulse: begin an op
    input  wire logic [1:0]  op,         // FXP_ADD / FXP_MUL / FXP_SUB / FXP_SUBR
    input  wire logic [79:0] a,
    input  wire logic [79:0] b,
    input  wire logic [1:0]  rc,         // rounding control (fctrl[11:10])
    input  wire logic [1:0]  pc,         // precision control (fctrl[9:8])
    output logic             vld,        // 1-clk pulse: {y,pe} valid (req + 2)
    output logic [79:0]      y,
    output logic             pe          // inexact (float_flag_inexact)
);
  // ---- op encodings (mirror f_eval_s1's sub-op numbering where they overlap)
  localparam logic [1:0] FXP_ADD  = 2'd0;   // a + b
  localparam logic [1:0] FXP_MUL  = 2'd1;   // a * b
  localparam logic [1:0] FXP_SUB  = 2'd2;   // a - b
  localparam logic [1:0] FXP_SUBR = 2'd3;   // b - a

  // ---- stage 1 -> stage 2 pipeline registers --------------------------------
  fx_pipe_t   p_q;
  logic [1:0] rc_q, pc_q;
  logic       s2_q;                        // stage-2 occupied this clock

  // ---- stage-1 front (combinational; registered into p_q) --------------------
  fx_pipe_t p_s1;
  always_comb begin
    unique case (op)
      FXP_ADD:  p_s1 = fx_add_s1(a, b, rc);
      FXP_MUL:  p_s1 = fx_mul_s1(a, b);
      FXP_SUB:  p_s1 = fx_add_s1(a, {~b[79], b[78:0]}, rc);   // a - b
      default:  p_s1 = fx_add_s1(b, {~a[79], a[78:0]}, rc);   // b - a  (SUBR)
    endcase
  end

  // ---- stage-2 back (combinational round-and-pack of the REGISTERED p_q) -----
  // p_q.result is {ie,ze,oe,ue,pe,fx80}; fx_round_pack_f gives {oe,ue,pe,fx80}.
  // In both encodings bit[80] is PE and [79:0] is the floatx80.
  wire [82:0] rp_w = fx_round_pack_f(p_q.sign, p_q.unbiased, p_q.sig,
                                     p_q.pre_inexact, rc_q, pc_q);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s2_q <= 1'b0; vld <= 1'b0; y <= 80'd0; pe <= 1'b0;
    end else begin
      vld  <= 1'b0;
      s2_q <= req;
      if (req) begin                       // stage 1 capture
        p_q  <= p_s1;
        rc_q <= rc;
        pc_q <= pc;
      end
      if (s2_q) begin                      // stage 2 commit
        y   <= p_q.early ? p_q.result[79:0] : rp_w[79:0];
        pe  <= p_q.early ? p_q.result[80]   : rp_w[80];
        vld <= 1'b1;
      end
    end
  end
endmodule

`default_nettype wire
