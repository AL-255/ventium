// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/fpu/fpu_f2xm1.sv — ITERATIVE x87 F2XM1 (2^x - 1) engine, #11.
//
// A microcoded, multi-cycle engine (handshake mirrors ven_bcd_to_fp /
// fpu_srt_div: start / busy / done-1clk-strobe / result), gated into the core
// behind +VEN_TRANSCENDENTAL. F2XM1 is a rare instruction, so this trades cycles
// for area: one floatx80 op (fx_mul / fx_add) OR one wide-int step per clock.
//
// ALGORITHM — a verbatim transcription of qemu-8.2.2 helper_f2xm1
// (target/i386/tcg/fpu_helper.c) + the fpu/softfloat.c routines it calls. That
// is the project's `make verify` oracle, so reproducing it bit-for-bit makes the
// DEFAULT (+VEN_TRANSCENDENTAL) build a real exact gate. The executable
// definition + the proof it equals real qemu-i386 (193/193) is
// tools/p5xtrans/qref.c (QREF-F2XM1-QEMU-OK). The ROM (65-entry t/2^t/2^t-1 table
// + 8 Horner coeffs + ln2) is fpu_f2xm1_rom.svh, generated from the SAME source.
//
// DUAL-MODE (docs/m11 §3.4): F2XM1's QEMU softfloat algorithm is ITSELF the P5
// accuracy-faithful one (80-bit table+Horner+reconstruct, ~0.5 ulp == silicon),
// with no catastrophic-reduction divergence (that is FSIN-near-pi's story, not
// F2XM1's). So this single datapath serves both QEMU and silicon (+VEN_TRSC_SILICON)
// modes; tools/p5xtrans/p5xtrans.c remains the silicon-accuracy oracle and was
// shown to agree to <1 ulp. The `silicon` parameter is reserved for symmetry with
// the FSIN/FCOS engines (where the modes genuinely diverge) — inert here.
//
// The floatx80 Horner runs in round-nearest (QEMU forces RNE there); only the
// final normalizeRoundAndPackFloatx80 honours the user RC (`rc` port).
// ===========================================================================
`default_nettype none

module fpu_f2xm1
  import fpu_x87_pkg::*;
#(
    parameter bit SILICON = 1'b0       // reserved (see header); F2XM1 path is shared
)(
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,    // 1-clk: begin (ignored if busy)
    input  wire logic [79:0] x,        // ST0 (floatx80)
    input  wire logic [1:0]  rc,       // rounding control fctrl[11:10]
    output logic             busy,
    output logic             done,     // 1-clk strobe: result valid
    output logic [79:0]      result    // floatx80 (== qemu helper_f2xm1)
);
  // localparam ROM (table + coefficients), generated from the qemu source.
  `include "fpu_f2xm1_rom.svh"

  // ---- wide-integer helpers (exact transcription of softfloat-macros.h) -----
  function automatic int clz64(input logic [63:0] v);
    begin
      clz64 = 64;
      for (int i=63; i>=0; i--) if (v[i]) begin clz64 = 63-i; break; end
    end
  endfunction

  // shift128RightJamming(a0,a1,count) -> {z0[127:64], z1[63:0]}
  function automatic logic [127:0] shift128rj(input logic [63:0] a0, input logic [63:0] a1,
                                              input int count);
    logic [63:0] z0, z1; int negc;
    begin
      negc = (-count) & 63;
      if (count == 0) begin z1 = a1; z0 = a0; end
      else if (count < 64) begin
        z1 = (a0<<negc) | (a1>>count) | (((a1<<negc)!=64'd0) ? 64'd1 : 64'd0);
        z0 = a0>>count;
      end else begin
        if (count == 64)       z1 = a0 | ((a1!=64'd0) ? 64'd1 : 64'd0);
        else if (count < 128)  z1 = (a0>>(count&63)) | ((((a0<<negc)|a1)!=64'd0) ? 64'd1 : 64'd0);
        else                   z1 = (((a0|a1)!=64'd0) ? 64'd1 : 64'd0);
        z0 = 64'd0;
      end
      shift128rj = {z0, z1};
    end
  endfunction

  // top 128 bits of mul128By64To192(a0,a1,b) — qemu DROPS the low 64 (z2); the
  // final asig1|=1 supplies the sticky/inexact. == (a0*b) + hi64(a1*b).
  function automatic logic [127:0] mul128_hi(input logic [63:0] a0, input logic [63:0] a1,
                                             input logic [63:0] b);
    logic [127:0] p_a0b, p_a1b;
    begin
      p_a0b = {64'd0, a0} * {64'd0, b};
      p_a1b = {64'd0, a1} * {64'd0, b};
      mul128_hi = p_a0b + {64'd0, p_a1b[127:64]};
    end
  endfunction

  // normalizeRoundAndPackFloatx80(precision_x) — normal path (the only one
  // F2XM1 results reach: |result| in [~2^-79, 1], never tiny/overflow).
  function automatic logic [79:0] norm_round_pack_x(input logic sign,
        input logic signed [31:0] expIn, input logic [63:0] sig0In,
        input logic [63:0] sig1In, input logic [1:0] rcv);
    logic [63:0] zSig0, zSig1; logic signed [31:0] zExp; int sc; logic inc, rne;
    begin
      zSig0 = sig0In; zSig1 = sig1In; zExp = expIn;
      if (zSig0 == 64'd0) begin zSig0 = zSig1; zSig1 = 64'd0; zExp = zExp - 32'sd64; end
      sc = clz64(zSig0);
      if (sc != 0 && sc < 64) begin
        zSig0 = (zSig0<<sc) | (zSig1>>(64-sc));
        zSig1 = zSig1<<sc;
      end
      zExp = zExp - sc;
      rne = (rcv == 2'd0);
      unique case (rcv)
        2'd0:    inc = zSig1[63];                 // nearest-even (tie handled below)
        2'd1:    inc = sign & (zSig1 != 64'd0);   // toward -inf
        2'd2:    inc = (~sign) & (zSig1 != 64'd0);// toward +inf
        default: inc = 1'b0;                      // truncate
      endcase
      if (inc) begin
        zSig0 = zSig0 + 64'd1;
        if (zSig0 == 64'd0) begin zExp = zExp + 32'sd1; zSig0 = 64'h8000000000000000; end
        else if (((zSig1<<1) == 64'd0) && rne) zSig0 = zSig0 & ~64'd1;
      end else begin
        if (zSig0 == 64'd0) zExp = 32'sd0;
      end
      norm_round_pack_x = {sign, zExp[14:0], zSig0};
    end
  endfunction

  // odd-Horner-step coefficient (steps 1,3,5,7,9,11,13 -> c6,c5,c4,c3,c2,c1,c0_low)
  function automatic logic [79:0] horner_coeff(input logic [3:0] step);
    begin
      unique case (step)
        4'd1:  horner_coeff = F2_C6;
        4'd3:  horner_coeff = F2_C5;
        4'd5:  horner_coeff = F2_C4;
        4'd7:  horner_coeff = F2_C3;
        4'd9:  horner_coeff = F2_C2;
        4'd11: horner_coeff = F2_C1;
        default: horner_coeff = F2_C0_LOW;        // step 13
      endcase
    end
  endfunction

  // ---- state ---------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE, S_SETUP, S_HORNER, S_RECON, S_RECONB, S_PACK, S_DONE
  } state_t;
  state_t st;

  logic [79:0] x_q, y_q, accum_q, result_q;
  logic [1:0]  rc_q;
  logic [6:0]  n_q;                 // table index 0..64
  logic [3:0]  step_q;
  logic signed [31:0] aexp_q;
  logic        asign_q;
  logic [63:0] asig0_q, asig1_q;
  logic        done_q;

  assign busy   = (st != S_IDLE);
  assign done   = done_q;
  assign result = result_q;

  // input-field shorthands
  wire [14:0] x_exp  = x[78:64];
  wire        x_sign = x[79];
  wire [63:0] x_man  = x[63:0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE; done_q <= 1'b0;
    end else begin
      done_q <= 1'b0;
      unique case (st)
        // -----------------------------------------------------------------
        S_IDLE: begin
          if (start) begin
            x_q  <= x;
            rc_q <= rc;
            st   <= S_SETUP;
          end
        end
        // ---- classify + range-reduce ------------------------------------
        S_SETUP: begin
          if (x_exp > 15'h3fff || (x_exp == 15'h3fff && x_man != 64'h8000000000000000)) begin
            result_q <= {16'hffff, 64'hc000000000000000};   // out of range -> default NaN
            st <= S_DONE;
          end else if (x_exp == 15'h3fff) begin
            result_q <= x_sign ? {16'hbffe, 64'h8000000000000000} : x_q;  // f2xm1(-+1)
            st <= S_DONE;
          end else if (x_exp < 15'h3fb0) begin
            if (fx_is_zero(x_q)) begin
              result_q <= x_q;                              // +-0 unchanged
              st <= S_DONE;
            end else begin
              // tiny: result ~ x*ln2 (extended) -> normalizeRoundAndPack.
              automatic logic [127:0] p;
              p = mul128_hi(F2_LN2_HI, F2_LN2_LO, x_man);
              asig0_q <= p[127:64];
              asig1_q <= p[63:0] | 64'd1;                   // inexact
              aexp_q  <= $signed({17'd0, x_exp});
              asign_q <= x_sign;
              st <= S_PACK;
            end
          end else begin
            // polynomial path: n = 32 + round_RNE(x*32); y = x - t[n].
            automatic logic [79:0] scaled, tval, ydiff;
            automatic logic signed [63:0] ni;
            automatic logic [6:0] nn;
            scaled = {x_sign, x_exp + 15'd5, x_man};        // floatx80_scalbn(x,5)
            // RNE-to-int. fx_to_int's 128-bit `1<<shift` overflows for |v|<2^-64,
            // mis-rounding tiny magnitudes to +-1; but |x*32|<0.5 (exp<0x3ffe)
            // always rounds to 0, so short-circuit that range explicitly.
            ni     = ((x_exp + 15'd5) < 15'h3ffe) ? 64'sd0 : fx_to_int(scaled);
            nn     = 7'(32 + ni);
            tval   = F2_T[nn];
            ydiff  = fx_add(x_q, {~tval[79], tval[78:0]}, 2'd0)[79:0];  // x - t[n]
            n_q    <= nn;
            y_q    <= ydiff;
            if (fx_is_zero(ydiff)) begin
              result_q <= tval;                             // qemu: ST0 = table[n].t
              st <= S_DONE;
            end else begin
              accum_q <= F2_C7;                             // step0 = C7*y
              step_q  <= 4'd0;
              st <= S_HORNER;
            end
          end
        end
        // ---- Horner: 14 steps, one fx_mul / fx_add per clock ------------
        S_HORNER: begin
          if (step_q[0] == 1'b0) accum_q <= fx_mul(accum_q, y_q, 2'd0)[79:0];      // accum*y
          else                   accum_q <= fx_add(horner_coeff(step_q), accum_q, 2'd0)[79:0];
          if (step_q == 4'd13) st <= S_RECON;
          step_q <= step_q + 4'd1;
        end
        // ---- reconstruct: poly = c0 + accum, then * y -------------------
        S_RECON: begin
          automatic logic signed [31:0] caexp, acexp;
          automatic logic [127:0] sh, asig, bsig, prod;
          caexp = $signed({17'd0, F2_C0[78:64]});           // 0x3ffe
          acexp = $signed({17'd0, accum_q[78:64]});
          sh    = shift128rj(accum_q[63:0], 64'd0, caexp - acexp);
          bsig  = {F2_C0[63:0], 64'd0};
          asig  = (accum_q[79] == F2_C0[79]) ? (bsig + sh) : (bsig - sh);  // add/sub128
          prod  = mul128_hi(asig[127:64], asig[63:0], y_q[63:0]);
          asig0_q <= prod[127:64];
          asig1_q <= prod[63:0];
          aexp_q  <= caexp + ($signed({17'd0, y_q[78:64]}) - 32'sd16382);  // +exp(y)-0x3ffe
          asign_q <= F2_C0[79] ^ y_q[79];
          st <= (n_q == 7'd32) ? S_PACK : S_RECONB;
        end
        // ---- reconstruct B: * 2^t, + (2^t - 1)  [n != 32] ---------------
        S_RECONB: begin
          automatic logic [79:0] e2, em;
          automatic logic signed [31:0] e2exp, bexp, ae;
          automatic logic [127:0] amul, asig, bsig;
          automatic logic        bsign;
          e2 = F2_E2[n_q]; em = F2_EM[n_q];
          // asig *= frac(2^t); aexp += exp(2^t) - 0x3ffe
          amul = mul128_hi(asig0_q, asig1_q, e2[63:0]);
          e2exp = $signed({17'd0, e2[78:64]});
          ae   = aexp_q + (e2exp - 32'sd16382);
          asig = amul;
          // align (2^t - 1) and asig to a common exponent
          bexp = $signed({17'd0, em[78:64]});
          bsig = {em[63:0], 64'd0};
          if (bexp < ae)      bsig = shift128rj(em[63:0], 64'd0, ae - bexp);
          else if (ae < bexp) begin asig = shift128rj(asig[127:64], asig[63:0], bexp - ae); ae = bexp; end
          bsign = em[79];
          if (asign_q == bsign) begin
            asig = shift128rj(asig[127:64], asig[63:0], 1);
            bsig = shift128rj(bsig[127:64], bsig[63:0], 1);
            ae   = ae + 32'sd1;
            asig = asig + bsig;                             // add128
            asig0_q <= asig[127:64]; asig1_q <= asig[63:0];
            aexp_q  <= ae;
          end else begin
            asig = bsig - asig;                             // sub128
            asig0_q <= asig[127:64]; asig1_q <= asig[63:0];
            aexp_q  <= ae;
            asign_q <= bsign;
          end
          st <= S_PACK;
        end
        // ---- final round/pack -------------------------------------------
        S_PACK: begin
          result_q <= norm_round_pack_x(asign_q, aexp_q, asig0_q, asig1_q | 64'd1, rc_q);
          done_q   <= 1'b1;
          st       <= S_IDLE;
`ifdef F2_DBG
          $display("DBG pack n=%0d aexp=%0d asign=%b asig0=%016h asig1=%016h yexp=%h",
                   n_q, aexp_q, asign_q, asig0_q, asig1_q, y_q[78:64]);
`endif
        end
        // ---- special-result delivery ------------------------------------
        S_DONE: begin
          done_q <= 1'b1;
          st     <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
