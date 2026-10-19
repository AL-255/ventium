// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/fpu/fpu_fsincos.sv — ITERATIVE x87 FSIN/FCOS/FSINCOS/FPTAN core, #11.
//
// Computes sin(x) AND cos(x) (the caller picks). qemu computes these with the
// build HOST's glibc (NOT bit-exact reproducible), so this is the SILICON-accuracy
// model in hardware: octant reduction (3-part Cody-Waite pi/2) + Taylor sin/cos,
// evaluated with fx_mul/fx_add == the C model's floatx80 ops. So it is graded
// BIT-EXACT vs tools/p5xtrans qref (qfsin/qfcos), whose accuracy is ~1.8 ulp vs
// quad truth (qref --validate-trig). Constants ROM = fpu_fsincos_rom.svh.
//
// c2=1 when |x| >= 2^63 (out of range): the x87 C2 flag is set and ST0 is left
// unchanged (the core handles that); sin_o/cos_o then carry x.
// Handshake mirrors fpu_f2xm1. Gated behind +VEN_TRANSCENDENTAL.
//
// ---------------------------------------------------------------------------
// PERF (#11 fmax/area rework): the arithmetic now runs through ONE shared,
// PIPELINED floatx80 ALU (fpu_fx_ppl) instead of inline combinational fx_mul /
// fx_add. The old Horner step was
//     sp <= fx80(fx_add(fx80(fx_mul(sp, r2, ...)), sinc(idx), ...));
//     cp <= fx80(fx_add(fx80(fx_mul(cp, r2, ...)), cosc(idx), ...));
// i.e. TWO full floatx80 ops (two round-and-packs) CHAINED in one clock, and
// duplicated for the parallel sin/cos chains — four op instances, ~167 ns of
// logic. That single path set the whole core's fmax (~6 MHz) and cost the area
// that pushed the all-transcendental build past placement.
//
// Now each op is issued to fpu_fx_ppl and its result awaited, so a clock holds
// at most ONE pipeline stage and the four parallel ops collapse to one datapath.
// fpu_fx_ppl is bit-identical to fx_mul/fx_add (it IS their s1 front +
// fx_round_pack_f back), so the qref gate result is unchanged — only the cycle
// count grows, which is irrelevant for a rare instruction that now runs on a
// much faster clock.
// ===========================================================================
`default_nettype none

module fpu_fsincos
  import fpu_x87_pkg::*;
#(
    parameter bit SILICON = 1'b0
)(
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,
    input  wire logic [79:0] x,
    output logic             busy,
    output logic             done,
    output logic [79:0]      sin_o,
    output logic [79:0]      cos_o,
    output logic             c2_o      // out of range (|x| >= 2^63)
);
  `include "fpu_fsincos_rom.svh"

  function automatic logic [79:0] sinc(input logic [3:0] k);
    begin
      unique case (k)
        4'd0: sinc=T_SIN0; 4'd1: sinc=T_SIN1; 4'd2: sinc=T_SIN2; 4'd3: sinc=T_SIN3;
        4'd4: sinc=T_SIN4; 4'd5: sinc=T_SIN5; 4'd6: sinc=T_SIN6; 4'd7: sinc=T_SIN7;
        4'd8: sinc=T_SIN8; 4'd9: sinc=T_SIN9; default: sinc=T_SIN10;
      endcase
    end
  endfunction
  function automatic logic [79:0] cosc(input logic [3:0] k);
    begin
      unique case (k)
        4'd0: cosc=T_COS0; 4'd1: cosc=T_COS1; 4'd2: cosc=T_COS2; 4'd3: cosc=T_COS3;
        4'd4: cosc=T_COS4; 4'd5: cosc=T_COS5; 4'd6: cosc=T_COS6; 4'd7: cosc=T_COS7;
        4'd8: cosc=T_COS8; 4'd9: cosc=T_COS9; default: cosc=T_COS10;
      endcase
    end
  endfunction
  function automatic logic [79:0] negf(input logic [79:0] v); negf = {~v[79], v[78:0]}; endfunction

  localparam int NT = 11;

  // ---- shared pipelined floatx80 ALU (op codes mirror fpu_fx_ppl) -----------
  localparam logic [1:0] FXP_ADD = 2'd0, FXP_MUL = 2'd1, FXP_SUB = 2'd2;

  logic        fx_req, fx_vld;
  logic [1:0]  fx_op;
  logic [79:0] fx_a, fx_b, fx_y;
  logic        fx_pe_unused;   // trig PE is forced by the core (sin/cos always inexact)

  fpu_fx_ppl u_fx (
    .clk(clk), .rst_n(rst_n),
    .req(fx_req), .op(fx_op), .a(fx_a), .b(fx_b),
    .rc(2'd0), .pc(2'b11),                       // RNE / 64-bit, as the old inline calls
    .vld(fx_vld), .y(fx_y), .pe(fx_pe_unused)
  );

  // ---- FSM: one state per arithmetic op (issue -> await vld -> consume) -----
  typedef enum logic [3:0] {
    S_IDLE,
    S_R0M,                    // m   = x * (2/pi)
    S_R1M, S_R1S,             // prod = nf * pio2_k ; r = r - prod   (k = 1..3)
    S_P0,                     // r2  = r * r
    S_PSM, S_PSA,             // sp  = sp*r2 + sinc(idx)
    S_PCM, S_PCA,             // cp  = cp*r2 + cosc(idx)
    S_FIN,                    // sp  = sp * r
    S_QUAD, S_DONE
  } state_t;
  state_t st;

  logic [79:0] x_q, r_q, r2_q, nf_q, sp_q, cp_q, tmp_q, sin_q, cos_q;
  logic [1:0]  quad_q;
  logic [3:0]  redk_q, polyk_q;
  logic        done_q, c2_q, iss_q;

  assign busy=(st!=S_IDLE); assign done=done_q;
  assign sin_o=sin_q; assign cos_o=cos_q; assign c2_o=c2_q;

  wire [14:0] x_exp=x_q[78:64];
  // |x| >= 2^63  <=> unbiased exp >= 63  <=> exp >= 0x3fff+63 = 0x403e
  wire x_oor = (x_exp >= 15'h403e);
  // Horner coefficient index: k counts 1..10 -> index (NT-1-k) = 9..0
  wire [3:0] idx = 4'(NT-1) - polyk_q;
  wire [79:0] pio2_k = (redk_q==4'd1) ? T_PIO2_1 : (redk_q==4'd2) ? T_PIO2_2 : T_PIO2_3;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st<=S_IDLE; done_q<=1'b0; fx_req<=1'b0; iss_q<=1'b0;
    end else begin
      done_q<=1'b0;
      fx_req<=1'b0;
      unique case (st)
        S_IDLE: if (start) begin
          x_q<=x; c2_q<=1'b0; redk_q<=4'd0; iss_q<=1'b0; st<=S_R0M;
        end

        // ---- reduction: n = round(x*2/pi); nf = (float)n; r = x -------------
        S_R0M: begin
          if (x_oor) begin
            // out of range: C2 set, ST0 untouched (carried out on sin_o/cos_o)
            c2_q<=1'b1; sin_q<=x_q; cos_q<=x_q; st<=S_DONE;
          end else if (!iss_q) begin
            fx_req<=1'b1; fx_op<=FXP_MUL; fx_a<=x_q; fx_b<=T_2OPI; iss_q<=1'b1;
          end else if (fx_vld) begin
            automatic logic signed [63:0] ni;
            ni      = (fx_y[78:64] < 15'h3ffe) ? 64'sd0 : fx_to_int(fx_y);  // |m|<0.5 -> 0
            quad_q <= ni[1:0];
            nf_q   <= fx_from_int(ni, 2'b11);
            r_q    <= x_q;
            redk_q <= 4'd1; iss_q<=1'b0; st<=S_R1M;
          end
        end

        // ---- r -= nf * pio2_k, for the 3 Cody-Waite pi/2 pieces -------------
        S_R1M: begin
          if (!iss_q) begin
            fx_req<=1'b1; fx_op<=FXP_MUL; fx_a<=nf_q; fx_b<=pio2_k; iss_q<=1'b1;
          end else if (fx_vld) begin
            tmp_q<=fx_y; iss_q<=1'b0; st<=S_R1S;
          end
        end
        S_R1S: begin
          if (!iss_q) begin
            fx_req<=1'b1; fx_op<=FXP_SUB; fx_a<=r_q; fx_b<=tmp_q; iss_q<=1'b1;  // r - prod
          end else if (fx_vld) begin
            r_q<=fx_y; iss_q<=1'b0;
            if (redk_q==4'd3) begin polyk_q<=4'd0; st<=S_P0; end
            else begin redk_q<=redk_q+4'd1; st<=S_R1M; end
          end
        end

        // ---- Horner over r2 for sin and cos ---------------------------------
        S_P0: begin
          if (!iss_q) begin
            fx_req<=1'b1; fx_op<=FXP_MUL; fx_a<=r_q; fx_b<=r_q; iss_q<=1'b1;
          end else if (fx_vld) begin
            r2_q<=fx_y;
            sp_q<=sinc(4'(NT-1));            // SINC[10]
            cp_q<=cosc(4'(NT-1));            // COSC[10]
            polyk_q<=4'd1; iss_q<=1'b0; st<=S_PSM;
          end
        end
        S_PSM: begin
          if (!iss_q) begin
            fx_req<=1'b1; fx_op<=FXP_MUL; fx_a<=sp_q; fx_b<=r2_q; iss_q<=1'b1;
          end else if (fx_vld) begin tmp_q<=fx_y; iss_q<=1'b0; st<=S_PSA; end
        end
        S_PSA: begin
          if (!iss_q) begin
            fx_req<=1'b1; fx_op<=FXP_ADD; fx_a<=tmp_q; fx_b<=sinc(idx); iss_q<=1'b1;
          end else if (fx_vld) begin sp_q<=fx_y; iss_q<=1'b0; st<=S_PCM; end
        end
        S_PCM: begin
          if (!iss_q) begin
            fx_req<=1'b1; fx_op<=FXP_MUL; fx_a<=cp_q; fx_b<=r2_q; iss_q<=1'b1;
          end else if (fx_vld) begin tmp_q<=fx_y; iss_q<=1'b0; st<=S_PCA; end
        end
        S_PCA: begin
          if (!iss_q) begin
            fx_req<=1'b1; fx_op<=FXP_ADD; fx_a<=tmp_q; fx_b<=cosc(idx); iss_q<=1'b1;
          end else if (fx_vld) begin
            cp_q<=fx_y; iss_q<=1'b0;
            if (polyk_q==4'(NT-1)) st<=S_FIN;
            else begin polyk_q<=polyk_q+4'd1; st<=S_PSM; end
          end
        end

        // ---- sin(r) = sp * r -------------------------------------------------
        S_FIN: begin
          if (!iss_q) begin
            fx_req<=1'b1; fx_op<=FXP_MUL; fx_a<=sp_q; fx_b<=r_q; iss_q<=1'b1;
          end else if (fx_vld) begin sp_q<=fx_y; iss_q<=1'b0; st<=S_QUAD; end
        end

        // ---- quadrant select --------------------------------------------------
        S_QUAD: begin
          unique case (quad_q)
            2'd0: begin sin_q<=sp_q;       cos_q<=cp_q;       end
            2'd1: begin sin_q<=cp_q;       cos_q<=negf(sp_q); end
            2'd2: begin sin_q<=negf(sp_q); cos_q<=negf(cp_q); end
            default: begin sin_q<=negf(cp_q); cos_q<=sp_q;    end
          endcase
          st<=S_DONE;
        end

        S_DONE: begin done_q<=1'b1; st<=S_IDLE; end
        default: st<=S_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
