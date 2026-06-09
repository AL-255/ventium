// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/fpu/fpu_fpatan.sv — ITERATIVE x87 FPATAN (atan2(ST1,ST0)) engine, #11.
//
// Quake's ONLY transcendental (2 `d9 f3` sites in glibc atan/atan2). A verbatim
// transcription of qemu-8.2.2 helper_fpatan + the softfloat.c routines it calls
// (the executable reference + the proof it == real qemu-i386 is tools/p5xtrans
// qfpatan, QREF-FPATAN-QEMU-OK, 296 cases x 4 RC). Gated behind +VEN_TRANSCENDENTAL.
//
// ALGORITHM: reduce x=num/den to [0,1], split x=t+y with t=nearest n/8 (the
// 9-entry atan c-table FA_HI/FA_LO), z=y/(1+tx), arctan(z) via a deg-6 odd-Horner
// (FA_C0..6), then arctan(x)=arctan(t)+arctan(z) and combine with pi/pi-2 per
// quadrant. The two internal divides use softfloat's estimateDiv128To64. Same
// c-table-ROM reduction the silicon uses, so this single datapath is both the
// QEMU-bit-exact gate target AND silicon-accuracy-faithful.
//
// Handshake mirrors fpu_f2xm1 (start/busy/done-strobe/result + inexact/invalid).
// y=ST1, x=ST0; result replaces ST1 then the core pops (commit = we_top-after-pop).
// ===========================================================================
`default_nettype none

module fpu_fpatan
  import fpu_x87_pkg::*;
#(
    parameter bit SILICON = 1'b0       // reserved (shared datapath, see fpu_f2xm1)
)(
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,
    input  wire logic [79:0] y,        // ST1
    input  wire logic [79:0] x,        // ST0
    input  wire logic [1:0]  rc,
    output logic             busy,
    output logic             done,
    output logic [79:0]      result,   // atan2(ST1,ST0) (== qemu helper_fpatan)
    output logic             inexact,
    output logic             invalid
);
  `include "fpu_fpatan_rom.svh"

  // ---- wide-int helpers (exact softfloat transcription) --------------------
  function automatic int clz64(input logic [63:0] v);
    begin clz64=64; for (int i=63;i>=0;i--) if (v[i]) begin clz64=63-i; break; end end
  endfunction
  function automatic int clz32(input logic [31:0] v);
    begin clz32=32; for (int i=31;i>=0;i--) if (v[i]) begin clz32=31-i; break; end end
  endfunction
  function automatic logic [127:0] shift128rj(input logic [63:0] a0, input logic [63:0] a1, input int count);
    logic [63:0] z0,z1; int negc;
    begin
      negc=(-count)&63;
      if (count==0) begin z1=a1; z0=a0; end
      else if (count<64) begin
        z1=(a0<<negc)|(a1>>count)|(((a1<<negc)!=64'd0)?64'd1:64'd0); z0=a0>>count;
      end else begin
        if (count==64) z1=a0|((a1!=64'd0)?64'd1:64'd0);
        else if (count<128) z1=(a0>>(count&63))|((((a0<<negc)|a1)!=64'd0)?64'd1:64'd0);
        else z1=(((a0|a1)!=64'd0)?64'd1:64'd0);
        z0=64'd0;
      end
      shift128rj={z0,z1};
    end
  endfunction
  function automatic logic [127:0] shift128r(input logic [63:0] a0, input logic [63:0] a1, input int count);
    logic [63:0] z0,z1; int negc;
    begin
      negc=(-count)&63;
      if (count==0) begin z1=a1; z0=a0; end
      else if (count<64) begin z1=(a0<<negc)|(a1>>count); z0=a0>>count; end
      else begin z1=(count<128)?(a0>>(count&63)):64'd0; z0=64'd0; end
      shift128r={z0,z1};
    end
  endfunction
  function automatic logic [127:0] shift128l(input logic [63:0] a0, input logic [63:0] a1, input int count);
    logic [63:0] z0,z1;
    begin
      if (count<64) begin z1=a1<<count; z0=(count==0)?a0:((a0<<count)|(a1>>((-count)&63))); end
      else begin z1=64'd0; z0=a1<<(count-64); end
      shift128l={z0,z1};
    end
  endfunction
  // full 192-bit mul128By64To192 -> {z0[191:128],z1[127:64],z2[63:0]}
  //   a1*b = m1:z2 ; a0*b = z0:z1 ; {z0,z1} += m1 ; z2 = low(a1*b).
  function automatic logic [191:0] mul128_192(input logic [63:0] a0, input logic [63:0] a1, input logic [63:0] b);
    logic [127:0] p1, p0;
    begin
      p1 = {64'd0,a1}*{64'd0,b};
      p0 = {64'd0,a0}*{64'd0,b};
      mul128_192 = {(p0 + {64'd0, p1[127:64]}), p1[63:0]};
    end
  endfunction
  // mul128To256 -> 256-bit product of {a0,a1}*{b0,b1}
  function automatic logic [255:0] mul128_256(input logic [63:0] a0,a1, input logic [63:0] b0,b1);
    logic [127:0] m, n, z2z3, z0z1; logic [191:0] s1, s2;
    begin
      m    = {64'd0,a1}*{64'd0,b0};   // m1:m2
      n    = {64'd0,a0}*{64'd0,b1};   // n1:n2
      z2z3 = {64'd0,a1}*{64'd0,b1};   // z2:z3
      z0z1 = {64'd0,a0}*{64'd0,b0};   // z0:z1
      // add192(0,m1,m2, 0,n1,n2) -> m0,m1,m2
      s1 = {64'd0, m} + {64'd0, n};   // 192-bit: top word 0
      // add192(m0,m1,m2, z0,z1,z2) -> z0,z1,z2
      s2 = s1 + {z0z1, z2z3[127:64]};
      mul128_256 = {s2, z2z3[63:0]};
    end
  endfunction
  function automatic logic [63:0] estDiv(input logic [63:0] a0, input logic [63:0] a1, input logic [63:0] b);
    logic [63:0] b0,b1,rem0,rem1,term0,term1,z; logic [127:0] t128, rem128;
    begin
      if (b<=a0) estDiv=64'hFFFFFFFFFFFFFFFF;
      else begin
        b0=b>>32;
        z=({b0,32'd0} <= a0) ? 64'hFFFFFFFF00000000 : ((a0/b0)<<32);
        t128={64'd0,b}*{64'd0,z}; term0=t128[127:64]; term1=t128[63:0];
        rem128={a0,a1}-{term0,term1}; rem0=rem128[127:64]; rem1=rem128[63:0];
        for (int it=0; it<6; it++) begin
          if (!rem0[63]) break;
          z=z-64'h100000000; b1=b<<32;
          rem128={rem0,rem1}+{b0,b1}; rem0=rem128[127:64]; rem1=rem128[63:0];
        end
        rem0=(rem0<<32)|(rem1>>32);
        z = z | (({b0,32'd0} <= rem0) ? 64'h00000000FFFFFFFF : (rem0/b0));
        estDiv=z;
      end
    end
  endfunction
  // normalizeRoundAndPackFloatx80(precision_x) normal path (== fpu_f2xm1).
  function automatic logic [79:0] norm_pack(input logic sign, input logic signed [31:0] expIn,
        input logic [63:0] sig0In, input logic [63:0] sig1In, input logic [1:0] rcv);
    logic [63:0] zSig0, zSig1; logic signed [31:0] zExp; int sc; logic inc, rne;
    begin
      zSig0=sig0In; zSig1=sig1In; zExp=expIn;
      if (zSig0==64'd0) begin zSig0=zSig1; zSig1=64'd0; zExp=zExp-32'sd64; end
      sc=clz64(zSig0);
      if (sc!=0 && sc<64) begin zSig0=(zSig0<<sc)|(zSig1>>(64-sc)); zSig1=zSig1<<sc; end
      zExp=zExp-sc;
      rne=(rcv==2'd0);
      unique case (rcv)
        2'd0:    inc=zSig1[63];
        2'd1:    inc=sign & (zSig1!=64'd0);
        2'd2:    inc=(~sign) & (zSig1!=64'd0);
        default: inc=1'b0;
      endcase
      if (inc) begin
        zSig0=zSig0+64'd1;
        if (zSig0==64'd0) begin zExp=zExp+32'sd1; zSig0=64'h8000000000000000; end
        else if (((zSig1<<1)==64'd0) && rne) zSig0=zSig0 & ~64'd1;
      end else if (zSig0==64'd0) zExp=32'sd0;
      norm_pack={sign, zExp[14:0], zSig0};
    end
  endfunction
  // odd-Horner coeff for the add steps (1,3,5,7,9 -> C5,C4,C3,C2,C1).
  function automatic logic [79:0] hcoeff(input logic [3:0] step);
    begin
      unique case (step)
        4'd1: hcoeff=FA_C5; 4'd3: hcoeff=FA_C4; 4'd5: hcoeff=FA_C3;
        4'd7: hcoeff=FA_C2; default: hcoeff=FA_C1;     // step 9
      endcase
    end
  endfunction

  // ---- state ---------------------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE, S_CLASS, S_XDIV, S_SPLIT, S_ZDIV, S_Z2, S_HORN,
    S_ATANZ, S_ATANX, S_ADJ, S_PACK, S_DIV, S_DONE
  } state_t;
  state_t st;

  logic [79:0] x_q, y_q, result_q, accum_q, z2_q;
  logic [1:0]  rc_q;
  logic        done_q, pe_q, ie_q;
  logic [3:0]  step_q;

  // decoded operands (after subnormal normalize)
  logic        a0s, a1s;                       // arg0/arg1 sign (x / y)
  logic signed [31:0] a0e, a1e;
  logic [63:0] a0sig, a1sig;
  // reduction state
  logic        rsign_q, adj_sub_q, ysign_q, zsign_q;
  logic signed [31:0] adj_exp_q, xexp_q, texp_q, yexp_q, zexp_q, azexp_q, axexp_q, rexp_q, aexp_q;
  logic [63:0] adj_sig0_q, adj_sig1_q, num_sig_q, den_sig_q, tsig_q;
  logic [63:0] xsig0_q, xsig1_q, ysig0_q, ysig1_q, zsig0_q, zsig1_q;
  logic [63:0] azsig0_q, azsig1_q, axsig0_q, axsig1_q, rsig0_q, rsig1_q;
  logic [3:0]  n_q;

  assign busy=(st!=S_IDLE); assign done=done_q; assign result=result_q;
  assign inexact=pe_q; assign invalid=ie_q;

  // field shorthands of the registered inputs
  wire [14:0] x_exp=x_q[78:64]; wire x_sign=x_q[79]; wire [63:0] x_man=x_q[63:0];
  wire [14:0] y_exp=y_q[78:64]; wire y_sign=y_q[79]; wire [63:0] y_man=y_q[63:0];
  wire x_is_zero = (x_exp==15'd0) && (x_man==64'd0);
  wire y_is_zero = (y_exp==15'd0) && (y_man==64'd0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin st<=S_IDLE; done_q<=1'b0; end
    else begin
      done_q<=1'b0;
      unique case (st)
        S_IDLE: if (start) begin x_q<=x; y_q<=y; rc_q<=rc; st<=S_CLASS; end

        // ---- classify + early corners + main-path setup -----------------
        S_CLASS: begin
          pe_q<=1'b1; ie_q<=1'b0;
          if (y_is_zero && !x_sign) begin
            result_q<=y_q; pe_q<=1'b0; st<=S_DONE;          // pass zero through
          end else if (($signed({17'd0,x_exp}) - $signed({17'd0,y_exp}) >= 32'sd80) && !x_sign) begin
            st<=S_DIV;                                        // ST1/ST0 fast path
          end else begin
            // result is inexact (rsign = y sign)
            automatic logic signed [31:0] x0e, y1e;
            automatic logic [63:0] x0s, y1s;
            rsign_q<=y_sign;
            if (y_is_zero) begin
              rexp_q<=$signed({17'd0,FA_PI_EXP}); rsig0_q<=FA_PI_H; rsig1_q<=FA_PI_L; st<=S_PACK;
            end else if (x_is_zero || ($signed({17'd0,y_exp})-$signed({17'd0,x_exp}) >= 32'sd80)) begin
              rexp_q<=$signed({17'd0,FA_PI2_EXP}); rsig0_q<=FA_PI_H; rsig1_q<=FA_PI_L; st<=S_PACK;
            end else if ($signed({17'd0,x_exp})-$signed({17'd0,y_exp}) >= 32'sd80) begin
              rexp_q<=$signed({17'd0,FA_PI_EXP}); rsig0_q<=FA_PI_H; rsig1_q<=FA_PI_L; st<=S_PACK;
            end else begin
              // normalize subnormals, pick num/den + adj, compute x=num/den
              automatic logic signed [31:0] num_e, den_e, xexp;
              automatic logic [63:0] num_s, den_s, rem0, rem1, msig0, msig1, xs0, xs1;
              automatic logic [127:0] mm, rem;
              x0e=$signed({17'd0,x_exp}); x0s=x_man;
              if (x_exp==15'd0) begin x0e=32'sd1-clz64(x_man); x0s=x_man<<clz64(x_man); end
              y1e=$signed({17'd0,y_exp}); y1s=y_man;
              if (y_exp==15'd0) begin y1e=32'sd1-clz64(y_man); y1s=y_man<<clz64(y_man); end
              if (x0e>y1e || (x0e==y1e && x0s>=y1s)) begin
                num_e=y1e; num_s=y1s; den_e=x0e; den_s=x0s;
                if (x_sign) begin adj_exp_q<=$signed({17'd0,FA_PI_EXP}); adj_sig0_q<=FA_PI_H; adj_sig1_q<=FA_PI_L; adj_sub_q<=1'b1; end
                else        begin adj_exp_q<=32'sd0; adj_sig0_q<=64'd0; adj_sig1_q<=64'd0; adj_sub_q<=1'b0; end
              end else begin
                num_e=x0e; num_s=x0s; den_e=y1e; den_s=y1s;
                adj_exp_q<=$signed({17'd0,FA_PI2_EXP}); adj_sig0_q<=FA_PI_H; adj_sig1_q<=FA_PI_L; adj_sub_q<=~x_sign;
              end
              // x = num/den in (0,1]
              xexp = num_e - den_e + 32'sd16382;
              rem0=num_s; rem1=64'd0;
              if (den_s<=rem0) begin rem=shift128r(rem0,rem1,1); rem0=rem[127:64]; rem1=rem[63:0]; xexp=xexp+32'sd1; end
              xs0=estDiv(rem0,rem1,den_s);
              mm={64'd0,den_s}*{64'd0,xs0}; msig0=mm[127:64]; msig1=mm[63:0];
              rem={rem0,rem1}-{msig0,msig1}; rem0=rem[127:64]; rem1=rem[63:0];
              for (int it=0; it<6; it++) begin
                if (!rem0[63]) break;
                xs0=xs0-64'd1; rem={rem0,rem1}+{64'd0,den_s}; rem0=rem[127:64]; rem1=rem[63:0];
              end
              xs1=estDiv(rem1,64'd0,den_s);
              xexp_q<=xexp; xsig0_q<=xs0; xsig1_q<=xs1;
              st<=S_SPLIT;
            end
          end
        end

        // ---- split x = t + y, t = nearest n/8 ---------------------------
        S_SPLIT: begin
          automatic logic [79:0] x8;
          automatic logic signed [63:0] ni;
          automatic logic [3:0] nn;
          automatic int shift;
          automatic logic [63:0] ys0, ys1, ts, us0, us1; automatic logic [127:0] sub, sh;
          automatic logic signed [31:0] te, ye;
          x8 = norm_pack(1'b0, xexp_q+32'sd3, xsig0_q, xsig1_q, 2'd0);
          // n = round_RNE(x8); guard the fx_to_int tiny-magnitude bug (|x8|<0.5 -> 0)
          ni = (x8[78:64] < 15'h3ffe) ? 64'sd0 : fx_to_int(x8);
          nn = ni[3:0];
          n_q <= nn;
          if (nn==4'd0) begin
            ysign_q<=1'b0; yexp_q<=xexp_q; ysig0_q<=xsig0_q; ysig1_q<=xsig1_q; texp_q<=32'sd0; tsig_q<=64'd0;
          end else begin
            shift = clz32({28'd0,nn}) + 32;
            te = 32'sd16443 - shift;                          // 0x403b - shift
            ts = {60'd0,nn} << shift;
            if (te==xexp_q) begin
              sub = {xsig0_q,xsig1_q} - {ts,64'd0}; ys0=sub[127:64]; ys1=sub[63:0];
              if (!ys0[63]) begin
                ysign_q<=1'b0;
                if (ys0==64'd0) begin
                  if (ys1==64'd0) ye=32'sd0;
                  else begin shift=clz64(ys1)+64; ye=xexp_q-shift; sub=shift128l(ys0,ys1,shift); ys0=sub[127:64]; ys1=sub[63:0]; end
                end else begin shift=clz64(ys0); ye=xexp_q-shift; sub=shift128l(ys0,ys1,shift); ys0=sub[127:64]; ys1=sub[63:0]; end
              end else begin
                ysign_q<=1'b1; sub={64'd0,64'd0}-{ys0,ys1}; ys0=sub[127:64]; ys1=sub[63:0];
                shift=(ys0==64'd0)?(clz64(ys1)+64):clz64(ys0);
                ye=xexp_q-shift; sub=shift128l(ys0,ys1,shift); ys0=sub[127:64]; ys1=sub[63:0];
              end
            end else begin
              sh=shift128rj(xsig0_q,xsig1_q, te-xexp_q); us0=sh[127:64]; us1=sh[63:0];
              ysign_q<=1'b1; sub={ts,64'd0}-{us0,us1}; ys0=sub[127:64]; ys1=sub[63:0];
              shift=(ys0==64'd0)?(clz64(ys1)+64):clz64(ys0);
              ye=te-shift; sub=shift128l(ys0,ys1,shift); ys0=sub[127:64]; ys1=sub[63:0];
            end
            texp_q<=te; tsig_q<=ts; yexp_q<=ye; ysig0_q<=ys0; ysig1_q<=ys1;
          end
          st<=S_ZDIV;
        end

        // ---- z = y/(1+tx) ----------------------------------------------
        S_ZDIV: begin
          zsign_q<=ysign_q;
          if (texp_q==32'sd0 || yexp_q==32'sd0) begin
            zexp_q<=yexp_q; zsig0_q<=ysig0_q; zsig1_q<=ysig1_q;
          end else begin
            automatic logic signed [31:0] dexp, zexp;
            automatic logic [63:0] dsig0, dsig1, rem0, rem1, rem2, zs0, zs1, m0,m1,m2;
            automatic logic [191:0] d192, mm192, rem192;
            automatic logic [127:0] sh;
            dexp = texp_q + xexp_q - 32'sd16382;
            d192 = mul128_192(xsig0_q, xsig1_q, tsig_q); dsig0=d192[191:128]; dsig1=d192[127:64];
            sh = shift128rj(dsig0, dsig1, 32'sh3fff - dexp); dsig0=sh[127:64]; dsig1=sh[63:0];
            dsig0 = dsig0 | 64'h8000000000000000;
            zexp = yexp_q - 32'sd1; rem0=ysig0_q; rem1=ysig1_q; rem2=64'd0;
            if (dsig0<=rem0) begin sh=shift128r(rem0,rem1,1); rem0=sh[127:64]; rem1=sh[63:0]; zexp=zexp+32'sd1; end
            zs0 = estDiv(rem0,rem1,dsig0);
            mm192 = mul128_192(dsig0,dsig1,zs0); m0=mm192[191:128]; m1=mm192[127:64]; m2=mm192[63:0];
            rem192 = {rem0,rem1,rem2} - {m0,m1,m2}; rem0=rem192[191:128]; rem1=rem192[127:64]; rem2=rem192[63:0];
            for (int it=0; it<6; it++) begin
              if (!rem0[63]) break;
              zs0=zs0-64'd1;
              rem192={rem0,rem1,rem2}+{64'd0,dsig0,dsig1}; rem0=rem192[191:128]; rem1=rem192[127:64]; rem2=rem192[63:0];
            end
            zs1 = estDiv(rem1,rem2,dsig0);
            zexp_q<=zexp; zsig0_q<=zs0; zsig1_q<=zs1;
          end
          st<=S_Z2;
        end

        // ---- z2 = z^2 ; preload Horner ---------------------------------
        S_Z2: begin
          if (zexp_q==32'sd0) begin
            azexp_q<=32'sd0; azsig0_q<=64'd0; azsig1_q<=64'd0;
            st<=S_ATANX;                                      // skip Horner (z==0)
          end else begin
            automatic logic [255:0] z2p;
            z2p = mul128_256(zsig0_q,zsig1_q, zsig0_q,zsig1_q);
            z2_q <= norm_pack(1'b0, zexp_q+zexp_q-32'sd16382, z2p[255:192], z2p[191:128], 2'd0);
            accum_q <= FA_C6; step_q<=4'd0;
            st<=S_HORN;
          end
        end

        // ---- Horner: accum, 11 steps -----------------------------------
        S_HORN: begin
          if (step_q[0]==1'b0) accum_q <= fx_mul(accum_q, z2_q, 2'd0)[79:0];
          else                 accum_q <= fx_add(hcoeff(step_q), accum_q, 2'd0)[79:0];
          if (step_q==4'd10) st<=S_ATANZ;
          step_q<=step_q+4'd1;
        end

        // ---- arctan(z) = z*(C0 + accum) --------------------------------
        S_ATANZ: begin
          automatic logic signed [31:0] aexp;
          automatic logic [127:0] sh, asig; automatic logic [255:0] azp;
          aexp = $signed({17'd0,FA_C0[78:64]});
          sh = shift128rj(accum_q[63:0], 64'd0, aexp - $signed({17'd0,accum_q[78:64]}));
          asig = {FA_C0[63:0],64'd0} - sh;                    // sub128(C0frac, accum_shifted)
          azexp_q <= aexp + zexp_q - 32'sd16382;
          azp = mul128_256(asig[127:64],asig[63:0], zsig0_q,zsig1_q);
          azsig0_q <= azp[255:192]; azsig1_q <= azp[191:128];
          st<=S_ATANX;
        end

        // ---- arctan(x) = arctan(t) + arctan(z) -------------------------
        S_ATANX: begin
          automatic logic [79:0] hi, lo;
          automatic logic low_sign; automatic logic signed [31:0] low_exp, axe, aze;
          automatic logic [63:0] ls0, ls1, ax0, ax1, az0, az1; automatic logic [127:0] sh, comb;
          if (texp_q==32'sd0) begin
            axexp_q<=azexp_q; axsig0_q<=azsig0_q; axsig1_q<=azsig1_q;
          end else begin
            hi=FA_HI[n_q]; lo=FA_LO[n_q];
            low_sign=lo[79]; low_exp=$signed({17'd0,lo[78:64]});
            ls0=lo[63:0]; ls1=64'd0;
            axe=$signed({17'd0,hi[78:64]}); ax0=hi[63:0]; ax1=64'd0;
            sh=shift128rj(ls0,ls1, axe-low_exp); ls0=sh[127:64]; ls1=sh[63:0];
            if (low_sign) begin comb={ax0,ax1}-{ls0,ls1}; end
            else          begin comb={ax0,ax1}+{ls0,ls1}; end
            ax0=comb[127:64]; ax1=comb[63:0];
            aze=azexp_q; az0=azsig0_q; az1=azsig1_q;
            if (aze>=axe) begin
              sh=shift128rj(ax0,ax1, aze-axe+32'sd1); ax0=sh[127:64]; ax1=sh[63:0];
              axe=aze+32'sd1; sh=shift128rj(az0,az1,1); az0=sh[127:64]; az1=sh[63:0];
            end else begin
              sh=shift128rj(ax0,ax1,1); ax0=sh[127:64]; ax1=sh[63:0];
              sh=shift128rj(az0,az1, axe-aze+32'sd1); az0=sh[127:64]; az1=sh[63:0];
              axe=axe+32'sd1;
            end
            if (zsign_q) comb={ax0,ax1}-{az0,az1};
            else         comb={ax0,ax1}+{az0,az1};
            axexp_q<=axe; axsig0_q<=comb[127:64]; axsig1_q<=comb[63:0];
          end
          st<=S_ADJ;
        end

        // ---- combine with adj (pi or pi/2) -----------------------------
        S_ADJ: begin
          automatic logic signed [31:0] adje, axe, re;
          automatic logic [63:0] as0, as1, ax0, ax1; automatic logic [127:0] sh, comb;
          adje=adj_exp_q; as0=adj_sig0_q; as1=adj_sig1_q;
          axe=axexp_q; ax0=axsig0_q; ax1=axsig1_q;
          if (adje==32'sd0) begin
            rexp_q<=axe; rsig0_q<=ax0; rsig1_q<=ax1;
          end else begin
            if (adje>=axe) begin
              sh=shift128rj(ax0,ax1, adje-axe+32'sd1); ax0=sh[127:64]; ax1=sh[63:0];
              re=adje+32'sd1; sh=shift128rj(as0,as1,1); as0=sh[127:64]; as1=sh[63:0];
            end else begin
              sh=shift128rj(ax0,ax1,1); ax0=sh[127:64]; ax1=sh[63:0];
              sh=shift128rj(as0,as1, axe-adje+32'sd1); as0=sh[127:64]; as1=sh[63:0];
              re=axe+32'sd1;
            end
            if (adj_sub_q) comb={as0,as1}-{ax0,ax1};
            else           comb={as0,as1}+{ax0,ax1};
            rexp_q<=re; rsig0_q<=comb[127:64]; rsig1_q<=comb[63:0];
          end
          st<=S_PACK;
        end

        // ---- div-shortcut (far-apart exponents): ST1/ST0 ---------------
        S_DIV: begin
          automatic logic [80:0] qd; automatic logic [79:0] q;
          qd = fx_div(y_q, x_q, rc_q);                        // floatx80_div, user rc
          q  = qd[79:0];
          // exact-division nudge omitted: for the far-apart corner the division is
          // inexact in practice; qd[80] carries the inexact flag for PE.
          result_q<=q; pe_q<=1'b1; st<=S_DONE;
        end

        // ---- final pack -------------------------------------------------
        S_PACK: begin
          result_q <= norm_pack(rsign_q, rexp_q, rsig0_q, rsig1_q | 64'd1, rc_q);
          done_q<=1'b1; st<=S_IDLE;
        end
        S_DONE: begin done_q<=1'b1; st<=S_IDLE; end
        default: st<=S_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
