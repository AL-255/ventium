// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/fpu/fpu_srt_div.sv — UNIFIED iterative FDIV: divide + square-root.
//
// Consolidates the divide and square-root datapaths into ONE engine (the
// Pentium FDIV section "executes the floating-point divide, remainder, and
// square-root instructions"), removing the separate fpu_sqrt_iter module. The
// two operations share the FSM (start/busy/done + step counter), the special-
// operand handling, the result register, and the rounder. `mode` selects:
//   FD_DIV  : a / b   (radix-4 SRT, carry-save partial remainder + PLA digit
//             selection — preserves the documented FDIV-bug when `buggy`=1).
//   FD_SQRT : sqrt(a) (radix-4 SRT, 2 root bits/clock) — SHARES the divide's
//             carry-save 3:2 adder, x4 shift, ladder PLA, ones-complement word,
//             and remainder-sign rounder. Radicand normalized to X in [1/4,1)
//             (value=X*4^k); recurrence w=4w-r*(2R+r*4^-j) with the on-the-fly
//             partial root 2R as the "divisor" (column floor(16*2R)); special
//             first digit (divisor==2.0 = PLA edge); two's-complement negative
//             initial remainder. Bit-exact == IEEE/QEMU; golden model
//             tools/srt/sqrt_model.py. This replaces the 208-bit binary-
//             restoring array (fx_isqrt) with the ~80-bit carry-save datapath.
//
// Handshake: pulse `start` (with mode/a/b/rc/buggy stable) when !busy. The
// engine raises `busy`, runs, then pulses `done` for one clock with `result`
// valid ({inexact, floatx80}).
// ===========================================================================
`default_nettype none

module fpu_srt_div
  import fpu_x87_pkg::*;
(
    input  wire logic        clk,
    input  wire logic        rst_n,      // active-low synchronous reset
    input  wire logic        start,      // 1-clk: begin (ignored if busy)
    input  wire logic [1:0]  mode,       // 0=divide, 1=square-root, 2=remainder
    input  wire logic        prem1,      // rem: 1 = FPREM1 (round-nearest Q)
    input  wire logic        rem_underflow_mask, // accepted remainder CW.UM
    input  wire logic [79:0] a,          // dividend / radicand / ST0 (floatx80)
    input  wire logic [79:0] b,          // divisor / ST1 (floatx80; ignored for sqrt)
`ifdef VEN_SRT_REM_OPERAND_SPLIT
    // Used only by accepted FD_REM. The caller supplies the same architectural
    // operands as a/b would contain, independently of the divide/memory mux.
    input  wire logic [79:0] rem_a,
    input  wire logic [79:0] rem_b,
`endif
    input  wire logic [1:0]  rc,         // x87 rounding control (fctrl[11:10])
    input  wire logic [1:0]  pc,         // x87 precision control (fctrl[9:8]): 00=24b 10=53b 11=64b
    input  wire logic        buggy,      // 1 = buggy PLA (reproduce the FDIV flaw)
    output logic             busy,       // 1 while an op is in flight
    output logic             done,       // 1-clk strobe: result valid this clock
    output logic [82:0]      result,     // {oe, ue, pe, floatx80}; remainder uses UE only
    output logic             rounded_up, // div/sqrt C1; registered with result/done
    output logic [2:0]       rem_q012,   // rem: {q2,q1,q0} -> {C0,C3,C1}
    output logic             rem_c2,     // rem: 1 = partial (incomplete) reduction
    output logic             rem_ie      // rem: invalid-operation
);
  localparam logic [1:0] FD_DIV  = 2'd0;
  localparam logic [1:0] FD_SQRT = 2'd1;
  localparam logic [1:0] FD_REM  = 2'd2;
  localparam int   NSTEP   = 36;         // 36 radix-4 steps (72 q/root frac bits)

  typedef enum logic [3:0] {
    ST_IDLE, ST_DRUN, ST_DFIN, ST_QRUN, ST_QFIN, ST_RRUN, ST_RFIN, ST_RNORM, ST_SPECIAL
  } state_t;
  state_t st;

  logic [1:0]  mode_q;                   // latched op

  // ---- divide state --------------------------------------------------------
  logic                sign;
  logic signed [31:0]  ua, ub;
  logic [3:0]          d4;
  logic [79:0]         dfx;              // divisor significand * 2^72
  logic [79:0]         S, C;             // carry-save partial remainder
  logic signed [127:0] qacc;            // quotient accumulator
  logic [6:0]          k;                // divide step counter 0..NSTEP

  // ---- sqrt state (radix-4 SRT, shares S/C/k with the divide) ---------------
  // twoR = 2*R * 2^72: the on-the-fly partial root, doubled (the SRT "divisor").
  // corrpos = 72-2j: bit position of this digit's r*4^-j correction term.
  logic [79:0]         twoR;
  logic [6:0]          corrpos;

`ifdef VEN_FPREM
`ifdef VEN_SRT_REM_OPERAND_SPLIT
  wire [79:0] rem_input_a = rem_a;
  wire [79:0] rem_input_b = rem_b;
`else
  wire [79:0] rem_input_a = a;
  wire [79:0] rem_input_b = b;
`endif
  // ---- remainder (FPREM/FPREM1) state — radix-4 SRT integer divide D/mb on the
  // SHARED carry-save recurrence (D=ma<<nb; S/C/qacc reused from the divide). The
  // dividend D is streamed MSB-first 2 bits/clock from `dvd` (ma + nb trailing zeros,
  // parity-aligned), injected into S's LSB after each x4 shift. == tools/srt/rem_model.py.
  logic [65:0]         dvd;              // dividend shift register (parity-aligned ma)
  logic [63:0]         rmb;              // divisor mantissa
  logic                rsa;             // sign of ST0 (remainder takes ST0's sign)
  logic signed [16:0]  reb;             // remainder exponent base
  logic [6:0]          rnsteps;         // total radix-4 steps = ceil((64+nb)/2)
  logic                rc2, rprem1, rum;
  logic                rsmall_half; // small nearest quotient, exponent gap -1
  function automatic logic        rem_is_inf (input logic [79:0] v);
    return (v[78:64]==15'h7fff) && (v[63:0]==64'h8000000000000000); endfunction
  function automatic logic        rem_is_nan (input logic [79:0] v);
    return (v[78:64]==15'h7fff) && (v[63:0]!=64'h8000000000000000); endfunction
  function automatic logic        rem_is_zero(input logic [79:0] v);
    return (v[78:64]==15'd0) && (v[63:0]==64'd0); endfunction
  function automatic logic [79:0] rem_quiet  (input logic [79:0] v);
    return {v[79], 15'h7fff, 2'b11, v[61:0]}; endfunction
  // Unsupported x80 encodings precede NaNs; a signaling operand raises IE
  // even when the other operand supplies the quiet NaN result.
  function automatic logic rem_unsupported(input logic [79:0] v);
    return (v[78:64] != 15'd0) && !v[63];
  endfunction
  function automatic logic rem_snan(input logic [79:0] v);
    return rem_is_nan(v) && !v[62];
  endfunction
  function automatic logic [79:0] rem_canonical(input logic [79:0] v);
    // Pseudo-denormals are accepted, raise DE at the architectural shell,
    // and become canonical normals even when quotient zero bypasses SRT.
    return ((v[78:64] == 15'd0) && v[63]) ? {v[79], 15'd1, v[63:0]} : v;
  endfunction
  function automatic logic [79:0] rem_nan_result(input logic [79:0] x, y);
    logic xn, yn, xs, ys;
    xn = rem_is_nan(x); yn = rem_is_nan(y);
    xs = rem_snan(x); ys = rem_snan(y);
    if (!yn || (xn && !xs && ys)) return rem_quiet(x);
    if (!xn || (yn && !ys && xs)) return rem_quiet(y);
    // Same NaN kind: greatest significand; equal payload prefers positive.
    if (x[63:0] > y[63:0]) return rem_quiet(x);
    if (x[63:0] < y[63:0]) return rem_quiet(y);
    return rem_quiet(x[79] ? y : x);
  endfunction
  // Six binary decisions, rather than a 64-entry first-match chain.
  // Keep the all-zero result at 64; denormal exponent adjustment uses it.
  function automatic logic [6:0] rem_clz64(input logic [63:0] x);
    logic [31:0] w32;
    logic [15:0] w16;
    logic [7:0] w8;
    logic [3:0] w4;
    logic [1:0] w2;
    logic [5:0] n;
    n[5] = ~(|x[63:32]);
    w32 = n[5] ? x[31:0] : x[63:32];
    n[4] = ~(|w32[31:16]);
    w16 = n[4] ? w32[15:0] : w32[31:16];
    n[3] = ~(|w16[15:8]);
    w8 = n[3] ? w16[7:0] : w16[15:8];
    n[2] = ~(|w8[7:4]);
    w4 = n[2] ? w8[3:0] : w8[7:4];
    n[1] = ~(|w4[3:2]);
    w2 = n[1] ? w4[1:0] : w4[3:2];
    n[0] = ~w2[1];
    return (x == 64'd0) ? 7'd64 : {1'b0, n};
  endfunction
  localparam logic [79:0] RQNAN_INDEF = {1'b1, 15'h7fff, 1'b1, 63'h4000000000000000};
`endif

  // Highest known-one search in six binary decisions. Procedural if,
  // rather than ?:, retains the old loop's treatment of X/Z test bits.
  // The original divide ka/kb defaults and sqrt cz default mean that an
  // all-zero (or no-known-one) mantissa must return ZERO, not 64.
  function automatic logic [5:0] srt_input_clz64(input logic [63:0] x);
    logic [31:0] w32;
    logic [15:0] w16;
    logic [7:0] w8;
    logic [3:0] w4;
    logic [1:0] w2;
    logic [5:0] n;
    n = 6'd0;
    if (|x[63:32]) w32 = x[63:32];
    else begin w32 = x[31:0]; n[5] = 1'b1; end
    if (|w32[31:16]) w16 = w32[31:16];
    else begin w16 = w32[15:0]; n[4] = 1'b1; end
    if (|w16[15:8]) w8 = w16[15:8];
    else begin w8 = w16[7:0]; n[3] = 1'b1; end
    if (|w8[7:4]) w4 = w8[7:4];
    else begin w4 = w8[3:0]; n[2] = 1'b1; end
    if (|w4[3:2]) w2 = w4[3:2];
    else begin w2 = w4[1:0]; n[1] = 1'b1; end
    if (w2[1]) n[0] = 1'b0;
    else n[0] = 1'b1;
    if (|x) return n;
    return 6'd0;
  endfunction

  // Divide normalization exponent is bounded: -16445..16384.
  // Explicit narrow intermediate prevents 32-bit assignment context from
  // widening the subtractors. Sign-extend into the unchanged ua/ub registers.
  function automatic logic signed [31:0] srt_div_input_exp(
      input logic [14:0] encoded, input logic [5:0] shift);
    logic [14:0] effective;
    logic signed [15:0] adjusted;
    effective = (encoded == 15'd0) ? 15'd1 : encoded;
    adjusted = $signed({1'b0, effective}) - 16'sd16383 - $signed({10'd0, shift});
    return {{16{adjusted[15]}}, adjusted};
  endfunction

  // ---- result --------------------------------------------------------------
  logic [82:0]         result_q;          // {oe, ue, pe, floatx80}
  logic                done_q;
  // Final divide/root magnitude, selected at the last iterative step. Keeping
  // this selection ahead of a register prevents mode_q from feeding the long
  // leading-one/rounding cone while retaining one shared rounder.
  logic [127:0]        round_uq_q;
  logic signed [31:0] round_sh_q;

  assign busy   = (st != ST_IDLE);
  assign done   = done_q;

`ifdef VEN_DBG_WD
  // [VEN-FDIVHANG] stuck-detector: the SRT engine finishes in ~NSTEP+few cycles.
  // If it stays out of ST_IDLE >256 cycles it is HUNG -> log state+latched operands.
  logic [15:0] dbg_bcnt;
  logic [79:0] dbg_a, dbg_b; logic [1:0] dbg_mode;
  always_ff @(posedge clk) begin
    if (!rst_n) dbg_bcnt <= 16'd0;
    else if (st == ST_IDLE) begin
      dbg_bcnt <= 16'd0;
      if (start) begin dbg_a <= a; dbg_b <= b; dbg_mode <= mode; end
    end else begin
      dbg_bcnt <= dbg_bcnt + 16'd1;
      if (dbg_bcnt == 16'd256)
        $display("[VEN-FDIVHANG] SRT stuck st=%0d k=%0d mode=%0d a=%020x b=%020x rc=%0d pc=%0d",
                 st, k, dbg_mode, dbg_a, dbg_b, rc, pc);
    end
  end
`endif
  assign result = result_q;

  // ==========================================================================
  // DIVIDE per-step body — IDENTICAL to the prior fpu_srt_div / fx_srt_div.
  // ==========================================================================
  logic [6:0]          psum;
  logic signed [6:0]   P_idx;
  logic signed [2:0]   q;                 // divide digit
  logic signed [2:0]   rsq;               // sqrt digit (exposed for on-the-fly twoR)
  logic signed [127:0] qext;
  logic [79:0]         T, sxor, cmaj, Tdiv, Tsq, Fenc;
  logic [3:0]          d4_sqrt;
  logic                cf, cfdiv, cfsq;
`ifdef VEN_FPREM
  logic [6:0]          rpsum;             // rem partial-remainder index (P at LSBs)
  logic signed [6:0]   rPidx;
  logic signed [2:0]   rrq;               // rem digit
  logic [79:0]         Trem, rmb80;
  logic                cfrem;
`endif
  always_comb begin
    // shared truncated 4int.3frac partial-remainder index (S+C, carry-save).
    psum  = S[75:69] + C[75:69];
    P_idx = $signed(psum);

    // --- divide digit + subtraction term (UNCHANGED) ---
    q     = fx_srt_pla(P_idx, d4, buggy);
    qext  = q;
    cfdiv = (q > 0);
    unique case (q)
      3'sd2:   Tdiv = ~(dfx << 1);
      3'sd1:   Tdiv = ~dfx;
      3'sd0:   Tdiv = 80'd0;
      -3'sd1:  Tdiv = dfx;
      -3'sd2:  Tdiv = dfx << 1;
      default: Tdiv = 80'd0;
    endcase

    // --- sqrt digit (SHARES the divide PLA) + on-the-fly subtraction term ---
    // column D=floor(16*2R) from the partial root (clamp to 31; D=32 only at 2R=2).
    d4_sqrt = twoR[73] ? 4'd15 : twoR[71:68];
    if (k == 7'd0)                          // first digit: divisor==2.0 (PLA edge)
      rsq = (P_idx >= -7'sd7)  ? 3'sd0 :
            (P_idx >= -7'sd19) ? -3'sd1 : -3'sd2;
    else
      rsq = fx_srt_pla(P_idx, d4_sqrt, 1'b0);
    // F = 2R + r*4^-j  (correction r at bit corrpos = 72-2j), encoded in the word.
    Fenc  = twoR + ($signed({{77{rsq[2]}}, rsq}) <<< corrpos);
    cfsq  = (rsq > 0);
    unique case (rsq)
      3'sd2:   Tsq = ~(Fenc << 1);
      3'sd1:   Tsq = ~Fenc;
      3'sd0:   Tsq = 80'd0;
      -3'sd1:  Tsq = Fenc;
      -3'sd2:  Tsq = Fenc << 1;
      default: Tsq = 80'd0;
    endcase

`ifdef VEN_FPREM
    // --- rem digit (SHARES the divide PLA): integer-divide D/mb, divisor rmb at
    // bits [63:0], partial remainder P at the LSBs -> index = P/2^60 = (S+C)[66:60];
    // column floor(16*mb/2^63) = 16 + mb[62:59]. T = -q*mb (ones-complement subtract).
    rpsum = S[66:60] + C[66:60];
    rPidx = $signed(rpsum);
    rrq   = fx_srt_pla(rPidx, rmb[62:59], 1'b0);
    rmb80 = {16'b0, rmb};
    cfrem = (rrq > 0);
    unique case (rrq)
      3'sd2:   Trem = ~(rmb80 << 1);
      3'sd1:   Trem = ~rmb80;
      3'sd0:   Trem = 80'd0;
      -3'sd1:  Trem = rmb80;
      -3'sd2:  Trem = rmb80 << 1;
      default: Trem = 80'd0;
    endcase
`endif

    // --- shared carry-save 3:2 add (S ^ C ^ T, majority<<1, +1 for subtract) ---
    unique case (mode_q)
      FD_SQRT: begin T = Tsq;  cf = cfsq;  end
`ifdef VEN_FPREM
      FD_REM:  begin T = Trem; cf = cfrem; end
`endif
      default: begin T = Tdiv; cf = cfdiv; end
    endcase
    sxor = S ^ C ^ T;
    cmaj = ((S & C) | (S & T) | (C & T)) << 1;
    if (cf) cmaj[0] = 1'b1;
  end

  // DIVIDE rounding tail — IDENTICAL to the prior engine (final qacc/S/C) for the
  // IN-RANGE result; out-of-range (over/underflow) quotients are packed through the
  // shared fx_round_pack_f below. Denormal OPERANDS are clz-normalized at setup so
  // the SRT recurrence always sees a 1.f significand (ua/ub carry the eff exponent).
  logic [80:0]         rsum;
  logic                rem_nz, rs_pos, rs_neg, up, down, inexact, resid_pos, resid_neg;
  logic [127:0]        uq, keep, remv, half;
  int                  msb, floor_msb, extra;
  logic signed [31:0]  e, ebiased;
  // out-of-range pack: feed the SHARED fx_round_pack_f one UNROUNDED 64-bit window
  // (top-aligned) + a single residual sticky so it does ONE correct round across
  // the gradual-underflow / overflow grid (no double-round). The SRT over-estimate
  // (resid_neg: true value < keep_floor by < 1 ULP) is folded out by a floor
  // decrement BEFORE packing, so the value handed to the packer is keep_floor with
  // a non-negative residual = (remv!=0)||rs_pos.
  logic                oor;
  logic [127:0]        sigp, keepf;
  logic signed [31:0]  ep;
  logic                stickyp;
  logic [83:0]         packed_oor;
  always_comb begin
    rsum    = {1'b0, C} + {1'b0, S};
    // The partial remainder is TRUE-ZERO when the ones-complement carry-save sum
    // is 0 OR all-ones (-0); detecting BOTH fixes the spurious-inexact that
    // mis-rounded an EXACT quotient by 1 ULP under directed RC (fpu87 finding).
    // Multiply-free (no qacc*mb), so the engine stays small.
    rem_nz  = (rsum[79:0] != 80'd0) && (rsum[79:0] != {80{1'b1}});
    rs_neg  = rem_nz &&  rsum[79];
    rs_pos  = rem_nz && !rsum[79];
    // The final quotient/root choice was registered by the last iterative step:
    // divide uses qacc with SH=70; sqrt uses root_int=(twoR>>1) with SH=72.
    uq      = round_uq_q;
    msb     = 0;
    for (int i=127; i>=0; i--) if (uq[i]) begin msb=i; break; end
    floor_msb = msb;                              // before the independent PC64 round
    extra   = msb - 63;
    keep    = uq >> extra;
    remv    = uq & ((128'd1 << extra) - 128'd1);
    half    = 128'd1 << (extra-1);
    inexact   = (remv != 128'd0) || rs_pos || rs_neg;
    resid_pos = (remv != 128'd0) || rs_pos;          // true magnitude above keep
    resid_neg = (remv == 128'd0) && rs_neg;          // below keep (by < 1 ULP)
    up = 1'b0; down = 1'b0;
    unique case (rc)
      2'd0:
        if      (remv > half) up = 1'b1;
        else if (remv < half) up = 1'b0;
        else                  up = rs_pos ? 1'b1 : (rs_neg ? 1'b0 : keep[0]);
      // directed rounding keys off the residual DIRECTION (not just inexactness):
      2'd1: begin up =  sign && resid_pos; down = !sign && resid_neg; end  // toward -inf
      2'd2: begin up = !sign && resid_pos; down =  sign && resid_neg; end  // toward +inf
      default: down = resid_neg;                                          // truncate
    endcase
    if (up) begin
      keep = keep + 128'd1;
      if (keep[64]) begin keep = keep >> 1; msb = msb + 1; end
    end else if (down) begin
      keep = keep - 128'd1;                          // keep over-estimates by < 1 ULP
      if (!keep[63]) begin keep = {64'd0, 64'hFFFFFFFFFFFFFFFF}; msb = msb - 1; end
    end
    e       = (msb - round_sh_q) + (ua - ub);
    ebiased = e + 32'sd16383;

    // -------- out-of-range (over/underflow) pack via fx_round_pack_f ----------
    // ep = unbiased exponent of the *floor* window MSB (bit63). The 64-bit floor
    // significand keepf (top-aligned to bit127) + sticky go to the shared packer,
    // which applies gradual-underflow / overflow + the active RC in ONE round.
    keepf   = uq >> extra;                            // floor 64-bit window (unrounded)
    ep      = ($signed(floor_msb) - round_sh_q) + (ua - ub);
    if (resid_neg) begin                             // SRT over-shot by < 1 ULP
      keepf = keepf - 128'd1;
      if (!keepf[63]) begin
        keepf = {64'd0, 64'hFFFFFFFFFFFFFFFF};         // borrowed across pow2
        ep = ep - 32'sd1;
      end
    end
    stickyp = (remv != 128'd0) || rs_pos || resid_neg;        // any residual below floor
    sigp    = keepf << 64;                            // window MSB (bit63) -> bit127
    // The packer owns its rounding carry/borrow. It must receive the FLOOR's
    // exponent, not msb after PC64 rounding; otherwise an inline carry is
    // counted twice at PC24/53. Apply a floor borrow before replacing its MSB.
    // Pass pc: the floor-window packer rounds to 24/53/64 bits. For pc<64 this also
    // serves the IN-RANGE result (single-round to PC; no double-round), so divide/
    // sqrt honor x87 precision control. PC=64 keeps the fast inline path below.
    packed_oor = fx_round_pack_c1(sign, ep, sigp, stickyp, rc, pc);
    // route the engine through the packer when the quotient is over/underflowing the
    // floatx80 normal range (biased <= 0 -> underflow; >= 0x7FFF -> overflow). This
    // is the set fx_div used to send to fx_div_exact; the engine now owns it too.
    oor = (ebiased <= 32'sd0) || (ebiased >= 32'sd32767);
  end

  // ==========================================================================
  // Sequencer
  // ==========================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= ST_IDLE; done_q <= 1'b0; k <= '0;
      round_uq_q <= 128'd0; round_sh_q <= 32'sd70;
      rem_q012 <= 3'd0; rem_c2 <= 1'b0; rem_ie <= 1'b0;
      rounded_up <= 1'b0;
    end else begin
      done_q <= 1'b0;
      unique case (st)
        ST_IDLE: begin
          // qacc is dead in IDLE/sqrt/special. Every consuming operation
          // enters from IDLE, so zero it here without a late start-input CE.
          qacc <= 128'sd0;
`ifdef VEN_SRT_REM_OPERAND_SPLIT
          // C is consumed only by iterative states. Every entry initializes
          // it to zero here; special-result operations never consume it.
          // Do not put input-dependent special classification on its CE.
          C <= 80'd0;
`endif
          if (start) begin
            mode_q <= mode;
            // Special operands and remainder do not use arithmetic rounding
            // C1. Remainder quotient bits have their separate output below.
            rounded_up <= 1'b0;
`ifdef VEN_FPREM
            if (mode == FD_REM) begin
              // ---- remainder setup (== fpu_fprem) --------------------------
              logic [14:0] rea, rebe; logic [63:0] rma, rmbb;
              logic signed [16:0] rea_a, reb_a, rexpd;
              rea=rem_input_a[78:64]; rebe=rem_input_b[78:64]; rma=rem_input_a[63:0]; rmbb=rem_input_b[63:0];
              rsa<=rem_input_a[79]; rem_q012<=3'd0; rem_c2<=1'b0; rem_ie<=1'b0; rprem1<=prem1;
              rsmall_half <= 1'b0;
              rum <= rem_underflow_mask;
              if (rem_unsupported(rem_input_a) || rem_unsupported(rem_input_b)) begin
                result_q <= {3'b000, RQNAN_INDEF}; rem_ie <= 1'b1; st <= ST_SPECIAL;
              end else if (rem_is_nan(rem_input_a) || rem_is_nan(rem_input_b)) begin
                result_q <= {3'b000, rem_nan_result(rem_input_a, rem_input_b)};
                rem_ie <= rem_snan(rem_input_a) || rem_snan(rem_input_b);
                st <= ST_SPECIAL;
              end else if (rem_is_zero(rem_input_b) || rem_is_inf(rem_input_a)) begin
                result_q <= {3'b000, RQNAN_INDEF}; rem_ie<=1'b1; st <= ST_SPECIAL;
              end else if (rem_is_zero(rem_input_a) || rem_is_inf(rem_input_b)) begin
                if (!rem_underflow_mask && rem_input_a[78:64] == 15'd0 &&
                    !rem_input_a[63] && rem_input_a[63:0] != 64'd0) begin
                  S <= {16'd0, rem_input_a[63:0]}; reb <= 17'sd1;
                  rc2 <= 1'b0; rprem1 <= 1'b0; st <= ST_RNORM;
                end else begin
                  result_q <= {3'b000, rem_canonical(rem_input_a)}; st <= ST_SPECIAL;
                end
              end else begin
                rea_a = (rea ==15'd0) ? (17'sd1 - {10'd0, rem_clz64(rma)})  : $signed({2'b0, rea});
                reb_a = (rebe==15'd0) ? (17'sd1 - {10'd0, rem_clz64(rmbb)}) : $signed({2'b0, rebe});
                // Exponents and significands must describe the same value.
                // The old exponent-only adjustment mis-scaled subnormal inputs.
                if (rea == 15'd0) rma = rma << rem_clz64(rma);
                if (rebe == 15'd0) rmbb = rmbb << rem_clz64(rmbb);
                rexpd = rea_a - reb_a;
                if (rexpd < 0 || (rexpd==0 && rma < rmbb)) begin
                  // FPREM truncates Q to zero here. FPREM1 instead needs Q=1
                  // when |A/B| > 1/2; exactly 1/2 still selects even Q=0.
                  if (prem1 && ((rexpd == 0) ||
                      (rexpd == -17'sd1 && rma > rmbb))) begin
                    S <= {16'd0, rma};
                    rmb <= rmbb;
                    reb <= (rexpd == -17'sd1) ? rea_a : reb_a;
                    rc2 <= 1'b0;
                    rsmall_half <= (rexpd == -17'sd1);
                    // qacc is already cleared in IDLE. Reuse the exact
                    // remainder subtract/normalizer rather than add a datapath.
                    st <= ST_RNORM;
                  end else begin
                    if (!rem_underflow_mask && rem_input_a[78:64] == 15'd0 &&
                        !rem_input_a[63] && rem_input_a[63:0] != 64'd0) begin
                      S <= {16'd0, rem_input_a[63:0]}; reb <= 17'sd1;
                      rc2 <= 1'b0; rprem1 <= 1'b0; st <= ST_RNORM;
                    end else begin
                      result_q <= {3'b000, rem_canonical(rem_input_a)}; st <= ST_SPECIAL;
                    end
                  end
                end else begin
                  // nb = alignment bits (D = ma<<nb): expdiff (complete) or the
                  // partial-reduction count (>=64 -> reduce 32..63 bits, C2=1).
                  logic [6:0] nb; logic signed [16:0] ebe; logic [65:0] dvd0;
                  if (rexpd < 64) begin nb = rexpd[6:0];               ebe = reb_a; rc2<=1'b0; end
                  else            begin nb = 7'd32 + {2'b0,rexpd[4:0]}; ebe = reb_a + (rexpd - {10'd0,nb}); rc2<=1'b1; end
                  // SRT integer-divide setup: D = ma<<nb streamed MSB-first 2 bits/
                  // clk; parity-align (D's bitlen 64+nb -> even for radix-4 grouping).
                  dvd0 = nb[0] ? {1'b0, rma, 1'b0} : {rma, 2'b0};
                  rmb     <= rmbb;
                  reb     <= ebe;
                  S       <= {78'd0, dvd0[65:64]};    // inject first 2 dividend bits
`ifndef VEN_SRT_REM_OPERAND_SPLIT
                  C       <= 80'd0;
`endif
                  dvd     <= dvd0 << 2;
                  k       <= 7'd0;
                  rnsteps <= 7'd32 + ((nb + {6'd0, nb[0]}) >> 1);   // ceil((64+nb)/2)
                  st      <= ST_RRUN;
                end
              end
            end else
`endif
            if (mode == FD_SQRT) begin
              // ---- sqrt setup (== fx_sqrt; caller guarantees a >= 0) --------
              if (fx_is_zero(a) || fx_exp(a)==15'h7fff) begin
                result_q <= {3'b000, a};         // sqrt(+0)=+0, sqrt(-0)=-0, sqrt(+Inf)=+Inf
                st <= ST_SPECIAL;
              end else begin
                // Normalize the radicand to sig*2^ee (sig in [1,2)); denormals
                // (exp==0) need an explicit clz-shift (fx_man doesn't normalize).
                automatic logic [63:0]        manr = fx_man(a);
                automatic logic signed [31:0] ee   = fx_uexp_eff(a);
                automatic int                 cz   = 0;
                automatic logic [79:0]        xenc;     // X*2^72, X in [1/4,1)
                automatic logic signed [31:0] kexp;
                if (fx_exp(a) == 15'd0) begin
                  cz = int'(srt_input_clz64(manr));
                  manr = manr << cz;
                  ee   = -32'sd16382 - cz;
                end
                // value = X*4^k, X in [1/4,1): e odd -> X=sig/2,k=(e+1)/2 (Xenc=man<<8);
                //                              e even-> X=sig/4,k=e/2+1 (Xenc=man<<7).
                if (ee[0]) begin xenc = {16'b0, manr} << 8; kexp = (ee + 32'sd1) >>> 1; end
                else       begin xenc = {16'b0, manr} << 7; kexp = (ee >>> 1) + 32'sd1; end
                // initial carry-save remainder = 4*(X-1) (NEGATIVE), two's-complement.
                S       <= (xenc << 2) - (80'd1 << 74);
`ifndef VEN_SRT_REM_OPERAND_SPLIT
                C       <= 80'd0;
`endif
                twoR    <= (80'd1 << 73);     // 2R = 2 (R_0 = 1)
                corrpos <= 7'd70;             // 72-2*1
                ua      <= kexp; ub <= 32'sd0; sign <= 1'b0;
                k       <= 7'd0;
                st      <= ST_QRUN;
              end
            end else begin
              // ---- divide setup (== prior engine) --------------------------
              sign <= fx_sign(a) ^ fx_sign(b);
              if (fx_is_zero(b)) begin
                result_q <= {3'b000, fx_make(fx_sign(a) ^ fx_sign(b), 15'h7fff,
                                           64'h8000000000000000)};
                st <= ST_SPECIAL;
              end else if (fx_is_zero(a)) begin
                result_q <= {3'b000, fx_make(fx_sign(a) ^ fx_sign(b), 15'd0, 64'd0)};
                st <= ST_SPECIAL;
              end else begin
                // Normalize each significand so its leading 1 sits at bit63. NORMAL
                // operands already are (no shift, ua/ub == fx_uexp). DENORMAL operands
                // (exp==0) arrive UNNORMALIZED — clz-shift to bit63 and carry the
                // shift in the eff exponent so the SRT recurrence (which assumes a
                // 1.f significand) and the final exponent stay exact. Value model
                // mant*2^(uexp-63) is preserved by ua/ub -= (63-clz). The eligibility
                // guard in fpu_writeback was widened to route denormal / extreme-exp
                // divides here too, so the combinational fx_div_exact path is dead.
                automatic logic [63:0] ma_ = fx_man(a);
                automatic logic [63:0] mb_ = fx_man(b);
                automatic logic [5:0] lza = srt_input_clz64(ma_);
                automatic logic [5:0] lzb = srt_input_clz64(mb_);
                ma_  = ma_ << lza;
                mb_  = mb_ << lzb;
                ua   <= srt_div_input_exp(a[78:64], lza);
                ub   <= srt_div_input_exp(b[78:64], lzb);
                d4   <= mb_[62:59];
                dfx  <= {7'b0, mb_, 9'b0};
                S    <= {7'b0, ma_, 9'b0};
`ifndef VEN_SRT_REM_OPERAND_SPLIT
                C    <= 80'd0;
`endif
                k    <= '0;
                st   <= ST_DRUN;
              end
            end
          end
        end
        // ---- DIVIDE iterate ----------------------------------------------
        ST_DRUN: begin
          qacc <= qacc + (qext <<< (70 - 2*int'(k)));
          S    <= sxor << 2;
          C    <= cmaj << 2;
          if (k == NSTEP-1) begin
            round_uq_q <= qacc + (qext <<< (70 - 2*int'(k)));
            round_sh_q <= 32'sd70;
            st         <= ST_DFIN;
          end
          k    <= k + 7'd1;
        end
        ST_DFIN: begin
          result_q <= (oor || pc==2'b00 || pc==2'b10) ? packed_oor[82:0]
                          : {2'b00, inexact, fx_make(sign, ebiased[14:0], keep[63:0])};
          // Keeping an SRT overestimate with negative residual also rounds
          // magnitude upward, even though the inline `up` add did not fire.
          rounded_up <= (oor || pc==2'b00 || pc==2'b10) ? packed_oor[83]
                          : (up || (resid_neg && !down));
          done_q   <= 1'b1;
          st       <= ST_IDLE;
        end
        // ---- SQRT iterate (radix-4 SRT, shares the carry-save adder) ------
        ST_QRUN: begin
          S       <= sxor << 2;                 // shift partial remainder x4 (== divide)
          C       <= cmaj << 2;
          // on-the-fly root: 2R += 2*r*4^-j -> r << (73-2j) == r << (corrpos+1).
          twoR    <= twoR + ($signed({{77{rsq[2]}}, rsq}) <<< (corrpos + 7'd1));
          corrpos <= corrpos - 7'd2;
          if (k == NSTEP-1) begin
            // Match twoR's 80-bit wrap before widening the captured root.
            round_uq_q <= 128'((80'(twoR +
                ($signed({{77{rsq[2]}}, rsq}) <<< (corrpos + 7'd1)))) >> 1);
            round_sh_q <= 32'sd72;
            st         <= ST_QFIN;
          end
          k       <= k + 7'd1;
        end
        ST_QFIN: begin                          // shared remainder-sign rounder
          result_q <= (oor || pc==2'b00 || pc==2'b10) ? packed_oor[82:0]
                          : {2'b00, inexact, fx_make(1'b0, ebiased[14:0], keep[63:0])};
          rounded_up <= (oor || pc==2'b00 || pc==2'b10) ? packed_oor[83]
                          : (up || (resid_neg && !down));
          done_q   <= 1'b1;
          st       <= ST_IDLE;
        end
`ifdef VEN_FPREM
        // ---- REM radix-4 SRT integer-divide step (shares the carry-save adder) ---
        // sxor/cmaj = post-subtract of the current S/C (T=Trem). Q = 4Q + rrq. Then
        // shift x4 + inject the next 2 dividend bits; the LAST step leaves the
        // remainder UNSHIFTED (carry-save) for the final sign-correction.
        ST_RRUN: begin
          qacc <= (qacc <<< 2) + $signed({{125{rrq[2]}}, rrq});
          if (k == rnsteps - 7'd1) begin
            S  <= sxor;  C <= cmaj;             // final partial remainder (unshifted)
            st <= ST_RFIN;
          end else begin
            S   <= (sxor << 2) | {78'd0, dvd[65:64]};
            C   <= cmaj << 2;
            dvd <= dvd << 2;
          end
          k <= k + 7'd1;
        end
        // ---- REM final remainder sign-correction -> R in [0, mb), Q exact --------
        ST_RFIN: begin
          logic [79:0] Psum;
          Psum = C + S;                          // resolve carry-save (|R| < mb)
          if (Psum[79]) begin                    // negative -> +mb, Q-=1
            S    <= Psum + {16'd0, rmb};
            qacc <= qacc - 128'sd1;
          end else if (Psum[79:64]==16'd0 && Psum[63:0] >= rmb) begin
            S    <= Psum - {16'd0, rmb};
            qacc <= qacc + 128'sd1;
          end else begin
            S    <= Psum;
          end
          st <= ST_RNORM;
        end
        // ---- REM round (FPREM1) + normalize the remainder into floatx80 ----
        ST_RNORM: begin
          logic [6:0] lz; logic signed [16:0] e; logic [63:0] mant;
          logic [63:0] r, q_eff, rrem; logic s_eff; logic [64:0] two_r, rsub; logic rndup;
          rrem  = S[63:0];                        // corrected remainder (< mb)
          two_r = {rrem, 1'b0};
          rndup = rsmall_half || (rprem1 && !rc2 &&
                  ((two_r > {1'b0, rmb}) || ((two_r == {1'b0, rmb}) && qacc[0])));
          // For gap -1, use A's exponent: B's significand is doubled. The
          // admission test guarantees 0 < 2*mb-ma < mb, so 64 result bits suffice.
          rsub = (rsmall_half ? {rmb, 1'b0} : {1'b0, rmb}) - {1'b0, rrem};
          if (rndup) begin r = rsub[63:0]; s_eff = ~rsa; q_eff = qacc[63:0] + 64'd1; end
          else       begin r = rrem;       s_eff =  rsa; q_eff = qacc[63:0];          end
          if (r==64'd0) begin
            result_q <= {3'b000, s_eff, 15'd0, 64'd0};       // signed zero
          end else begin
            lz   = rem_clz64(r);
            mant = r << lz;
            e    = reb - {10'd0, lz};
            if (e <= 0 && !rum) begin
              logic signed [16:0] wrapped_e;
              // Exact tiny results still raise unmasked UE. Stack results
              // are scaled by 2^24576, without rounding or newly raised PE.
              wrapped_e = e + 17'sd24576;
              result_q <= {3'b010, s_eff, wrapped_e[14:0], mant};
            end else if (e <= 0) begin
              logic signed [16:0] ome; logic [6:0] rsh;
              ome = 17'sd1 - e;
              rsh = (ome > 17'sd63) ? 7'd63 : ome[6:0];
              result_q <= {3'b000, s_eff, 15'd0, (mant >> rsh)};
            end else begin
              result_q <= {3'b000, s_eff, e[14:0], mant};
            end
          end
          rem_q012 <= rc2 ? 3'd0 : q_eff[2:0];
          rem_c2   <= rc2;
          done_q   <= 1'b1;
          st       <= ST_IDLE;
        end
`endif
        ST_SPECIAL: begin
          done_q <= 1'b1;                       // result_q latched in ST_IDLE
          st     <= ST_IDLE;
        end
        default: st <= ST_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
