// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/fpu/fpu_fyl2x.sv — ITERATIVE x87 FYL2X / FYL2XP1 engine, #11.
//   mode=0: ST1 * log2(ST0)        (D9 F1, FYL2X)
//   mode=1: ST1 * log2(ST0 + 1)    (D9 F9, FYL2XP1)
//
// A verbatim transcription of qemu-8.2.2 helper_fyl2x / helper_fyl2xp1 and the
// shared helper_fyl2x_common (reference + proof == qemu-i386: tools/p5xtrans
// qfyl2x/qfyl2xp1, 316/324 cases x 4 RC). Gated behind +VEN_TRANSCENDENTAL.
//
// fyl2x_common: t = arg/(2+arg) (estimateDiv128To64), deg-9 odd-Horner of
// log2((1+t)/(1-t)) (FY_C0..9), * t. FYL2X adds the int_exp (2^k) part; FYL2XP1
// uses a log2(e) extra-precision tiny path. Both then multiply by ST1 and write
// ST1, then POP (commit = we_sti(1)+we_pop, like fpatan).
//
// Handshake mirrors fpu_fpatan. y=ST1, x=ST0, mode selects the op.
// ===========================================================================
`default_nettype none

module fpu_fyl2x
  import fpu_x87_pkg::*;
#(
    parameter bit SILICON = 1'b0
)(
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,
    input  wire logic        mode,      // 0=FYL2X, 1=FYL2XP1
    input  wire logic [79:0] y,         // ST1
    input  wire logic [79:0] x,         // ST0
    input  wire logic [1:0]  rc,
    output logic             busy,
    output logic             done,
    output logic [79:0]      result,
    output logic             inexact,
    output logic             invalid
);
  `include "fpu_fyl2x_rom.svh"
  `include "fpu_trsc_wideint.svh"

  function automatic logic [79:0] hcoeff(input logic [4:0] step);
    begin
      unique case (step)
        5'd1:  hcoeff=FY_C8; 5'd3:  hcoeff=FY_C7; 5'd5:  hcoeff=FY_C6;
        5'd7:  hcoeff=FY_C5; 5'd9:  hcoeff=FY_C4; 5'd11: hcoeff=FY_C3;
        5'd13: hcoeff=FY_C2; 5'd15: hcoeff=FY_C1; default: hcoeff=FY_C0_LOW; // 17
      endcase
    end
  endfunction

  typedef enum logic [3:0] {
    S_IDLE, S_CLASS, S_CDIV, S_CT2, S_CHORN, S_CRECON, S_POST, S_PACK, S_DONE
  } state_t;
  state_t st;

  logic [79:0] x_q, y_q, result_q, accum_q, t2_q;
  logic [1:0]  rc_q;
  logic        mode_q, done_q, pe_q, ie_q;
  logic [4:0]  step_q;

  // arg for fyl2x_common + the y (ST1) operand
  logic        arg_sign; logic signed [31:0] arg_exp; logic [63:0] arg_sig;
  logic        a1sign_q; logic signed [31:0] a1exp_q; logic [63:0] a1sig_q;
  logic        a0sign_x;                  // x's sign (FYL2XP1 result sign)
  logic signed [31:0] int_exp_q;
  // common results
  logic [63:0] tsig0_q, tsig1_q;  logic signed [31:0] texp_q;
  logic        asign_q; logic signed [31:0] aexp_q; logic [63:0] asig0_q, asig1_q;

  assign busy=(st!=S_IDLE); assign done=done_q; assign result=result_q;
  assign inexact=pe_q; assign invalid=ie_q;

  wire [14:0] x_exp=x_q[78:64]; wire x_sign=x_q[79]; wire [63:0] x_man=x_q[63:0];
  wire [14:0] y_exp=y_q[78:64]; wire y_sign=y_q[79]; wire [63:0] y_man=y_q[63:0];
  wire x_is_zero=(x_exp==15'd0)&&(x_man==64'd0);
  wire y_is_zero=(y_exp==15'd0)&&(y_man==64'd0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin st<=S_IDLE; done_q<=1'b0; end
    else begin
      done_q<=1'b0;
      unique case (st)
        S_IDLE: if (start) begin x_q<=x; y_q<=y; rc_q<=rc; mode_q<=mode; st<=S_CLASS; end

        // ---- classify + wrapper setup -----------------------------------
        S_CLASS: begin
          automatic logic signed [31:0] a0e, a1e; automatic logic [63:0] a0s, a1s;
          pe_q<=1'b1; ie_q<=1'b0; a0sign_x<=x_sign;
          // normalize subnormal operands
          a0e=$signed({17'd0,x_exp}); a0s=x_man;
          if (x_exp==15'd0) begin a0e=32'sd1-clz64(x_man); a0s=x_man<<clz64(x_man); end
          a1e=$signed({17'd0,y_exp}); a1s=y_man;
          if (y_exp==15'd0) begin a1e=32'sd1-clz64(y_man); a1s=y_man<<clz64(y_man); end
          a1sign_q<=y_sign; a1exp_q<=a1e; a1sig_q<=a1s;

          if (mode_q==1'b0) begin
            // ---- FYL2X ----
            automatic logic signed [31:0] ie2;
            automatic logic [79:0] scaled, m1;
            automatic logic signed [63:0] ie64;
            ie2 = a0e - 32'sd16383;
            if (a0s > FY_SQRT2THR) ie2 = ie2 + 32'sd1;
            scaled = {x_sign, 15'(a0e - ie2), a0s};           // scalbn(x,-int_exp)
            m1 = fx_add(scaled, 80'hbfff8000000000000000, 2'd0)[79:0];  // scaled - 1.0
            int_exp_q <= ie2;
            ie64 = ie2;
            if (m1[78:64]==15'd0 && m1[63:0]==64'd0) begin   // exact power of 2
              automatic logic [80:0] mr;
              mr = fx_mul(fx_from_int(ie64), y_q, rc_q);
              result_q <= mr[79:0]; pe_q <= mr[80]; st<=S_DONE;
            end else begin
              arg_sign<=m1[79]; arg_exp<=$signed({17'd0,m1[78:64]}); arg_sig<=m1[63:0];
              asign_q<=m1[79];
              st<=S_CDIV;
            end
          end else begin
            // ---- FYL2XP1 ----
            if (x_is_zero || y_is_zero || a1e==32'sd32767) begin
              automatic logic [80:0] mr; mr=fx_mul(x_q,y_q,rc_q);
              result_q<=mr[79:0]; pe_q<=mr[80]; st<=S_DONE;
            end else if (a0e < 32'sd16304) begin              // exp < 0x3fb0: log2e tiny path
              automatic logic [191:0] p; automatic logic [63:0] s0,s1; automatic logic signed [31:0] e;
              p=mul128_192(FY_LOG2E_H, FY_LOG2E_L, a0s); s0=p[191:128]; s1=p[127:64];
              e=a0e+32'sd1;
              p=mul128_192(s0,s1,a1s); s0=p[191:128]; s1=p[127:64];
              e=e + (a1e - 32'sd16382);
              result_q <= norm_pack(x_sign ^ y_sign, e, s0, s1|64'd1, rc_q);
              pe_q<=1'b1; st<=S_DONE;
            end else begin
              arg_sign<=x_sign; arg_exp<=a0e; arg_sig<=a0s;
              asign_q<=x_sign;
              st<=S_CDIV;
            end
          end
        end

        // ---- fyl2x_common: t = arg/(2+arg) ------------------------------
        S_CDIV: begin
          automatic logic signed [31:0] dexp, texp; automatic logic [63:0] dsig0,dsig1;
          automatic logic [63:0] rsig0,rsig1,rsig2, ts0, m0,m1b,m2; automatic logic [127:0] sh; automatic logic [191:0] mm, rem;
          if (arg_sign) begin
            dexp=32'sd16383; sh=shift128rj(arg_sig,64'd0, dexp-arg_exp); dsig0=sh[127:64]; dsig1=sh[63:0];
            sh = {64'd0,64'd0} - {dsig0,dsig1}; dsig0=sh[127:64]; dsig1=sh[63:0];
          end else begin
            dexp=32'sd16384; sh=shift128rj(arg_sig,64'd0, dexp-arg_exp); dsig0=sh[127:64]; dsig1=sh[63:0];
            dsig0=dsig0 | 64'h8000000000000000;
          end
          texp = arg_exp - dexp + 32'sd16382;
          rsig0=arg_sig; rsig1=64'd0; rsig2=64'd0;
          if (dsig0<=rsig0) begin sh=shift128r(rsig0,rsig1,1); rsig0=sh[127:64]; rsig1=sh[63:0]; texp=texp+32'sd1; end
          ts0 = estDiv(rsig0,rsig1,dsig0);
          mm = mul128_192(dsig0,dsig1,ts0); m0=mm[191:128]; m1b=mm[127:64]; m2=mm[63:0];
          rem = {rsig0,rsig1,rsig2} - {m0,m1b,m2}; rsig0=rem[191:128]; rsig1=rem[127:64]; rsig2=rem[63:0];
          for (int it=0; it<6; it++) begin
            if (!rsig0[63]) break;
            ts0=ts0-64'd1; rem={rsig0,rsig1,rsig2}+{64'd0,dsig0,dsig1}; rsig0=rem[191:128]; rsig1=rem[127:64]; rsig2=rem[63:0];
          end
          tsig0_q<=ts0; tsig1_q<=estDiv(rsig1,rsig2,dsig0); texp_q<=texp;
          st<=S_CT2;
        end

        // ---- t2 = t^2 ; preload Horner ----------------------------------
        S_CT2: begin
          automatic logic [255:0] t2p;
          t2p = mul128_256(tsig0_q,tsig1_q, tsig0_q,tsig1_q);
          t2_q <= norm_pack(1'b0, texp_q+texp_q-32'sd16382, t2p[255:192], t2p[191:128], 2'd0);
          accum_q <= FY_C9; step_q<=5'd0;
          st<=S_CHORN;
        end

        // ---- deg-9 Horner: 18 steps -------------------------------------
        S_CHORN: begin
          if (step_q[0]==1'b0) accum_q <= fx_mul(accum_q, t2_q, 2'd0)[79:0];
          else                 accum_q <= fx_add(hcoeff(step_q), accum_q, 2'd0)[79:0];
          if (step_q==5'd17) st<=S_CRECON;
          step_q<=step_q+5'd1;
        end

        // ---- poly = (C0 + accum) * t ------------------------------------
        S_CRECON: begin
          automatic logic signed [31:0] aexp; automatic logic [127:0] sh, asig; automatic logic [255:0] ap;
          aexp = $signed({17'd0,FY_C0[78:64]});
          sh = shift128rj(accum_q[63:0], 64'd0, aexp - $signed({17'd0,accum_q[78:64]}));
          if (FY_C0[79]==accum_q[79]) asig = {FY_C0[63:0],64'd0} + sh;
          else                        asig = {FY_C0[63:0],64'd0} - sh;
          ap = mul128_256(asig[127:64],asig[63:0], tsig0_q,tsig1_q);
          aexp_q  <= aexp + texp_q - 32'sd16382;
          asig0_q <= ap[255:192]; asig1_q <= ap[191:128];
          st<=S_POST;
        end

        // ---- wrapper post: int_exp add (fyl2x) + mul by ST1 -------------
        S_POST: begin
          automatic logic signed [31:0] aexp; automatic logic [63:0] as0, as1; automatic logic asign;
          automatic logic [191:0] mp;
          aexp=aexp_q; as0=asig0_q; as1=asig1_q; asign=asign_q;
          if (mode_q==1'b0 && int_exp_q!=32'sd0) begin
            automatic logic isign; automatic logic signed [31:0] ie, iexp; automatic logic [63:0] isig; automatic int shift;
            automatic logic [127:0] sh, comb;
            isign = int_exp_q[31];
            ie = isign ? -int_exp_q : int_exp_q;
            shift = clz32(ie) + 32; isig = ie << shift; iexp = 32'sd16446 - shift;  // 0x403e - shift
            sh = shift128rj(as0,as1, iexp - aexp); as0=sh[127:64]; as1=sh[63:0];
            if (asign==isign) comb = {isig,64'd0} + {as0,as1};
            else              comb = {isig,64'd0} - {as0,as1};
            as0=comb[127:64]; as1=comb[63:0]; aexp=iexp; asign=isign;
          end
          // multiply by ST1 (arg1)
          mp = mul128_192(as0, as1, a1sig_q); as0=mp[191:128]; as1=mp[127:64];
          aexp = aexp + (a1exp_q - 32'sd16382);
          asign_q<=asign; aexp_q<=aexp; asig0_q<=as0; asig1_q<=as1|64'd1;
          st<=S_PACK;
        end

        S_PACK: begin
          result_q <= norm_pack(asign_q ^ a1sign_q, aexp_q, asig0_q, asig1_q, rc_q);
          pe_q<=1'b1; done_q<=1'b1; st<=S_IDLE;
        end
        S_DONE: begin done_q<=1'b1; st<=S_IDLE; end
        default: st<=S_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
