// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/fpu/fpu_estdiv.sv — SEQUENTIAL estimateDiv128To64 (#11 fmax).
//
// A cycle-by-cycle transcription of SoftFloat's estimateDiv128To64 (the
// `estDiv` function in fpu_trsc_wideint.svh), which the transcendental engines
// use to seed their quotient digits.
//
// WHY. As a COMBINATIONAL function estDiv contains, in a single clock:
//   * a 64/32 hardware divide            (a0 / b0)
//   * a 64x64 multiply + 128-bit subtract (b * z ; {a0,a1} - t)
//   * a SIX-deep chain of 128-bit adds    (the correction loop)
//   * a SECOND 64/32 hardware divide      (rem0 / b0)
// two dividers deep, and fpu_fyl2x's S_CDIV called it TWICE in one state. That
// is the transcendental logic that drove the routed WNS to -71 ns against the
// 167 ns (6 MHz) core period — i.e. a rare instruction was setting the whole
// core's clock.
//
// WHAT. The same arithmetic sequenced so no clock holds more than ONE heavy
// operation: one divide in E_D1, the multiply/subtract in E_MUL, ONE correction
// iteration per clock in E_CORR, the second divide in E_D2. Bit-exact with the
// combinational version by construction — identical expressions, identical
// order, identical early-outs — so the verif/trsc engine gates are unchanged.
//
// Handshake: pulse `req` with {a0,a1,b}; `vld` pulses with `z` when done
// (2 clocks for the b<=a0 saturation early-out, else 4 + up to 6 correction
// clocks). Callers are strictly sequential, so one instance can be shared.
// ===========================================================================
`default_nettype none

module fpu_estdiv (
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        req,      // 1-clk pulse: start
    input  wire logic [63:0] a0,       // dividend high
    input  wire logic [63:0] a1,       // dividend low
    input  wire logic [63:0] b,        // divisor
    output logic             vld,      // 1-clk pulse: z valid
    output logic [63:0]      z
);
  typedef enum logic [2:0] { E_IDLE, E_D1, E_MUL, E_CORR, E_D2 } est_t;
  est_t est;

  logic [63:0] a0_q, a1_q, b_q, b0_q, z_q, rem0_q, rem1_q;
  logic [2:0]  k_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      est <= E_IDLE; vld <= 1'b0; z <= 64'd0;
    end else begin
      vld <= 1'b0;
      unique case (est)
        // if (b <= a0) return 0xFFFFFFFFFFFFFFFF;  else b0 = b>>32;
        E_IDLE: if (req) begin
          if (b <= a0) begin
            z <= 64'hFFFFFFFFFFFFFFFF; vld <= 1'b1;
          end else begin
            a0_q <= a0; a1_q <= a1; b_q <= b; b0_q <= b >> 32;
            est <= E_D1;
          end
        end
        // z = ((b0<<32) <= a0) ? 0xFFFFFFFF00000000 : ((a0/b0)<<32);   [divide #1]
        E_D1: begin
          z_q <= ((b0_q << 32) <= a0_q) ? 64'hFFFFFFFF00000000
                                        : ((a0_q / b0_q) << 32);
          est <= E_MUL;
        end
        // t = b*z ; rem = {a0,a1} - t
        E_MUL: begin
          automatic logic [127:0] t128, rem128;
          t128   = {64'd0, b_q} * {64'd0, z_q};
          rem128 = {a0_q, a1_q} - t128;
          rem0_q <= rem128[127:64]; rem1_q <= rem128[63:0];
          k_q <= 3'd0; est <= E_CORR;
        end
        // for (it=0..5) { if (!rem0[63]) break; z -= 1<<32; rem += {b0, b<<32}; }
        // ONE iteration per clock (was six chained 128-bit adds in one clock).
        E_CORR: begin
          if (rem0_q[63] && (k_q != 3'd6)) begin
            automatic logic [127:0] rem128;
            rem128 = {rem0_q, rem1_q} + {b0_q, b_q << 32};
            z_q    <= z_q - 64'h100000000;
            rem0_q <= rem128[127:64]; rem1_q <= rem128[63:0];
            k_q    <= k_q + 3'd1;
          end else est <= E_D2;
        end
        // rem0 = (rem0<<32)|(rem1>>32);
        // z |= ((b0<<32) <= rem0) ? 0xFFFFFFFF : (rem0/b0);            [divide #2]
        E_D2: begin
          automatic logic [63:0] r0;
          r0 = (rem0_q << 32) | (rem1_q >> 32);
          z  <= z_q | (((b0_q << 32) <= r0) ? 64'h00000000FFFFFFFF
                                            : (r0 / b0_q));
          vld <= 1'b1; est <= E_IDLE;
        end
        default: est <= E_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
