// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// rtl/fpu/fpu_trsc_wideint.svh — the softfloat wide-integer kit shared by the
// x87 transcendental engines (#11). RAW function text `included inside a module
// (so the package's fx_* are in scope). Exact transcriptions of qemu-8.2.2
// fpu/softfloat-macros.h. (fpu_f2xm1/fpu_fpatan keep inline copies; fpu_fyl2x
// uses this include.)

  function automatic int clz64(input logic [63:0] v);
    begin clz64=64; for (int i=63;i>=0;i--) if (v[i]) begin clz64=63-i; break; end end
  endfunction
  function automatic int clz32(input logic [31:0] v);
    begin clz32=32; for (int i=31;i>=0;i--) if (v[i]) begin clz32=31-i; break; end end
  endfunction
  // shift128RightJamming -> {z0[127:64], z1[63:0]}
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
      m    = {64'd0,a1}*{64'd0,b0};
      n    = {64'd0,a0}*{64'd0,b1};
      z2z3 = {64'd0,a1}*{64'd0,b1};
      z0z1 = {64'd0,a0}*{64'd0,b0};
      s1 = {64'd0, m} + {64'd0, n};
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
        z=((b0<<32) <= a0) ? 64'hFFFFFFFF00000000 : ((a0/b0)<<32);
        t128={64'd0,b}*{64'd0,z}; term0=t128[127:64]; term1=t128[63:0];
        rem128={a0,a1}-{term0,term1}; rem0=rem128[127:64]; rem1=rem128[63:0];
        for (int it=0; it<6; it++) begin
          if (!rem0[63]) break;
          z=z-64'h100000000; b1=b<<32;
          rem128={rem0,rem1}+{b0,b1}; rem0=rem128[127:64]; rem1=rem128[63:0];
        end
        rem0=(rem0<<32)|(rem1>>32);
        z = z | (((b0<<32) <= rem0) ? 64'h00000000FFFFFFFF : (rem0/b0));
        estDiv=z;
      end
    end
  endfunction
  // normalizeRoundAndPackFloatx80(precision_x) normal path.
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
