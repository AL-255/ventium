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
  typedef enum logic [2:0] { S_IDLE, S_RED, S_POLY, S_FIN, S_QUAD, S_DONE } state_t;
  state_t st;

  logic [79:0] x_q, r_q, r2_q, nf_q, sp_q, cp_q, sin_q, cos_q;
  logic [1:0]  quad_q;
  logic [3:0]  redk_q, polyk_q;
  logic        done_q, c2_q;

  assign busy=(st!=S_IDLE); assign done=done_q;
  assign sin_o=sin_q; assign cos_o=cos_q; assign c2_o=c2_q;

  wire [14:0] x_exp=x_q[78:64]; wire [63:0] x_man=x_q[63:0];
  // |x| >= 2^63  <=> unbiased exp >= 63  <=> exp >= 0x3fff+63 = 0x403e
  wire x_oor = (x_exp >= 15'h403e);

  always_ff @(posedge clk) begin
    if (!rst_n) begin st<=S_IDLE; done_q<=1'b0; end
    else begin
      done_q<=1'b0;
      unique case (st)
        S_IDLE: if (start) begin x_q<=x; st<=S_RED; redk_q<=4'd0; c2_q<=1'b0; end

        // ---- reduction setup: n, nf; then r -= nf*PIO2_{1,2,3} -----------
        S_RED: begin
          if (redk_q==4'd0) begin
            // n = round(x*2/pi), guarded; nf = (float)n; r = x.
            automatic logic [79:0] m; automatic logic signed [63:0] ni;
            if (x_oor) begin
              c2_q<=1'b1; sin_q<=x_q; cos_q<=x_q; st<=S_DONE;
            end else begin
              m = fx_mul(x_q, T_2OPI, 2'd0)[79:0];
              ni = (m[78:64] < 15'h3ffe) ? 64'sd0 : fx_to_int(m);   // |m|<0.5 -> 0
              quad_q <= ni[1:0];
              nf_q   <= fx_from_int(ni);
              r_q    <= x_q;
              redk_q <= 4'd1;
            end
          end else begin
            automatic logic [79:0] pio2, prod;
            pio2 = (redk_q==4'd1) ? T_PIO2_1 : (redk_q==4'd2) ? T_PIO2_2 : T_PIO2_3;
            prod = fx_mul(nf_q, pio2, 2'd0)[79:0];
            r_q  <= fx_add(r_q, negf(prod), 2'd0)[79:0];           // r = r - nf*pio2
            if (redk_q==4'd3) begin st<=S_POLY; polyk_q<=4'd0; end
            else redk_q<=redk_q+4'd1;
          end
        end

        // ---- Horner: sp,cp over r2 (10 steps), then sp *= r --------------
        S_POLY: begin
          if (polyk_q==4'd0) begin
            r2_q <= fx_mul(r_q, r_q, 2'd0)[79:0];
            sp_q <= sinc(4'(NT-1));         // SINC[10]
            cp_q <= cosc(4'(NT-1));         // COSC[10]
            polyk_q <= 4'd1;
          end else begin
            // k counts 1..10 -> coefficient index (NT-1-k) = 9..0
            automatic logic [3:0] idx; idx = 4'(NT-1) - polyk_q;
            sp_q <= fx_add(fx_mul(sp_q, r2_q, 2'd0)[79:0], sinc(idx), 2'd0)[79:0];
            cp_q <= fx_add(fx_mul(cp_q, r2_q, 2'd0)[79:0], cosc(idx), 2'd0)[79:0];
            if (polyk_q==4'(NT-1)) st<=S_FIN;
            polyk_q<=polyk_q+4'd1;
          end
        end

        // ---- sin(r) = sp * r --------------------------------------------
        S_FIN: begin
          sp_q <= fx_mul(sp_q, r_q, 2'd0)[79:0];
          st<=S_QUAD;
        end

        // ---- quadrant select --------------------------------------------
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
