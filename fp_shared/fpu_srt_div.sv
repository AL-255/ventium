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
    input  wire logic [79:0] a,          // dividend / radicand / ST0 (floatx80)
    input  wire logic [79:0] b,          // divisor / ST1 (floatx80; ignored for sqrt)
    input  wire logic [1:0]  rc,         // x87 rounding control (fctrl[11:10])
    input  wire logic [1:0]  pc,         // x87 precision control (fctrl[9:8]): 00=24b 10=53b 11=64b
    input  wire logic        buggy,      // 1 = buggy PLA (reproduce the FDIV flaw)
    output logic             busy,       // 1 while an op is in flight
    output logic             done,       // 1-clk strobe: result valid this clock
    output logic [82:0]      result,     // {oe, ue, pe, floatx80}  (div/sqrt) | {2'b0, 1'b0, rem} (rem)
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
  // ---- remainder (FPREM/FPREM1) state — radix-4 SRT integer divide D/mb on the
  // SHARED carry-save recurrence (D=ma<<nb; S/C/qacc reused from the divide). The
  // dividend D is streamed MSB-first 2 bits/clock from `dvd` (ma + nb trailing zeros,
  // parity-aligned), injected into S's LSB after each x4 shift. == tools/srt/rem_model.py.
  logic [65:0]         dvd;              // dividend shift register (parity-aligned ma)
  logic [63:0]         rmb;              // divisor mantissa
  logic                rsa;             // sign of ST0 (remainder takes ST0's sign)
  logic signed [16:0]  reb;             // remainder exponent base
  logic [6:0]          rnsteps;         // total radix-4 steps = ceil((64+nb)/2)
  logic                rc2, rprem1;
  function automatic logic        rem_is_inf (input logic [79:0] v);
    return (v[78:64]==15'h7fff) && (v[63:0]==64'h8000000000000000); endfunction
  function automatic logic        rem_is_nan (input logic [79:0] v);
    return (v[78:64]==15'h7fff) && (v[63:0]!=64'h8000000000000000); endfunction
  function automatic logic        rem_is_zero(input logic [79:0] v);
    return (v[78:64]==15'd0) && (v[63:0]==64'd0); endfunction
  function automatic logic [79:0] rem_quiet  (input logic [79:0] v);
    return {v[79], 15'h7fff, 2'b11, v[61:0]}; endfunction
  function automatic logic [6:0]  rem_clz64(input logic [63:0] x);
    logic [6:0] n; n = 7'd64;
    for (int i=63;i>=0;i--) if (x[i] && n==7'd64) n = 7'd63 - i[6:0];
    return n; endfunction
  localparam logic [79:0] RQNAN_INDEF = {1'b1, 15'h7fff, 1'b1, 63'h4000000000000000};
`endif

  // ---- result --------------------------------------------------------------
  logic [82:0]         result_q;          // {oe, ue, pe, floatx80}
  logic                done_q;
  // Final divide/root magnitude, selected at the last iterative step.  Keeping
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
  int                  msb, extra;
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
  logic [82:0]         packed_oor;
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
    if (resid_neg) begin                             // SRT over-shot by < 1 ULP
      keepf = keepf - 128'd1;
      if (!keepf[63]) keepf = {64'd0, 64'hFFFFFFFFFFFFFFFF};  // borrowed across pow2
    end
    stickyp = (remv != 128'd0) || rs_pos || resid_neg;        // any residual below floor
    sigp    = keepf << 64;                            // window MSB (bit63) -> bit127
    // weight of keepf's MSB (bit63) == weight of uq bit `msb` (the floor window top):
    // (msb - SH) + (ua-ub), SH=70 (div) / 72 (sqrt). resid_neg's pow2-borrow drops
    // the window MSB one position, but fx_round_pack_f re-finds the MSB of sigp and
    // uses the passed weight as ITS top bit's exponent, so pass the floor MSB weight.
    ep      = ($signed(msb) - round_sh_q) + (ua - ub);
    if (resid_neg && !keepf[63]) ep = ep - 32'sd1;    // borrow crossed a power of two
    // Pass pc: the floor-window packer rounds to 24/53/64 bits. For pc<64 this also
    // serves the IN-RANGE result (single-round to PC; no double-round), so divide/
    // sqrt honor x87 precision control. PC=64 keeps the fast inline path below.
    packed_oor = fx_round_pack_f(sign, ep, sigp, stickyp, rc, pc);
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
    end else begin
      done_q <= 1'b0;
      unique case (st)
        ST_IDLE: begin
          if (start) begin
            mode_q <= mode;
`ifdef VEN_FPREM
            if (mode == FD_REM) begin
              // ---- remainder setup (== fpu_fprem) --------------------------
              logic [14:0] rea, rebe; logic [63:0] rma, rmbb;
              logic signed [16:0] rea_a, reb_a, rexpd;
              rea=a[78:64]; rebe=b[78:64]; rma=a[63:0]; rmbb=b[63:0];
              rsa<=a[79]; rem_q012<=3'd0; rem_c2<=1'b0; rem_ie<=1'b0; rprem1<=prem1;
              if (rem_is_nan(a) || rem_is_nan(b)) begin
                result_q <= {3'b000, (rem_is_nan(a) ? rem_quiet(a) : rem_quiet(b))};
                st <= ST_SPECIAL;
              end else if (rem_is_zero(b) || rem_is_inf(a)) begin
                result_q <= {3'b000, RQNAN_INDEF}; rem_ie<=1'b1; st <= ST_SPECIAL;
              end else if (rem_is_zero(a) || rem_is_inf(b)) begin
                result_q <= {3'b000, a}; st <= ST_SPECIAL;     // |a|<|b| or a==0
              end else begin
                rea_a = (rea ==15'd0) ? (17'sd1 - {10'd0, rem_clz64(rma)})  : $signed({2'b0, rea});
                reb_a = (rebe==15'd0) ? (17'sd1 - {10'd0, rem_clz64(rmbb)}) : $signed({2'b0, rebe});
                rexpd = rea_a - reb_a;
                if (rexpd < 0 || (rexpd==0 && rma < rmbb)) begin
                  result_q <= {3'b000, a}; st <= ST_SPECIAL;   // remainder = a, Q=0
                end else begin
                  // nb = alignment bits (D = ma<<nb): expdiff (complete) or the
                  // partial-reduction count (>=64 -> reduce 32..63 bits, C2=1).
                  logic [6:0] nb; logic signed [16:0] ebe; logic [65:0] dvd0;
                  if (rexpd < 64) begin nb = rexpd[6:0];               ebe = $signed({2'b0,rebe}); rc2<=1'b0; end
                  else            begin nb = 7'd32 + {2'b0,rexpd[4:0]}; ebe = $signed({2'b0,rebe}) + (rexpd - {10'd0,nb}); rc2<=1'b1; end
                  // SRT integer-divide setup: D = ma<<nb streamed MSB-first 2 bits/
                  // clk; parity-align (D's bitlen 64+nb -> even for radix-4 grouping).
                  dvd0 = nb[0] ? {1'b0, rma, 1'b0} : {rma, 2'b0};
                  rmb     <= rmbb;
                  reb     <= ebe;
                  S       <= {78'd0, dvd0[65:64]};    // inject first 2 dividend bits
                  C       <= 80'd0;
                  dvd     <= dvd0 << 2;
                  qacc    <= 128'sd0;
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
                  for (int i=63; i>=0; i--) if (manr[i]) begin cz = 63 - i; break; end
                  manr = manr << cz;
                  ee   = -32'sd16382 - cz;
                end
                // value = X*4^k, X in [1/4,1): e odd -> X=sig/2,k=(e+1)/2 (Xenc=man<<8);
                //                              e even-> X=sig/4,k=e/2+1 (Xenc=man<<7).
                if (ee[0]) begin xenc = {16'b0, manr} << 8; kexp = (ee + 32'sd1) >>> 1; end
                else       begin xenc = {16'b0, manr} << 7; kexp = (ee >>> 1) + 32'sd1; end
                // initial carry-save remainder = 4*(X-1) (NEGATIVE), two's-complement.
                S       <= (xenc << 2) - (80'd1 << 74);
                C       <= 80'd0;
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
                automatic int          ka  = 63;
                automatic int          kb  = 63;
                automatic logic signed [31:0] uae = fx_uexp_eff(a);
                automatic logic signed [31:0] ube = fx_uexp_eff(b);
                for (int i=63;i>=0;i--) if (ma_[i]) begin ka=i; break; end
                for (int i=63;i>=0;i--) if (mb_[i]) begin kb=i; break; end
                ma_  = ma_ << (63-ka);
                mb_  = mb_ << (63-kb);
                ua   <= uae - (63 - ka);
                ub   <= ube - (63 - kb);
                d4   <= mb_[62:59];
                dfx  <= {7'b0, mb_, 9'b0};
                S    <= {7'b0, ma_, 9'b0};
                C    <= 80'd0;
                qacc <= 128'sd0;
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
          logic [63:0] r, q_eff, rrem; logic s_eff; logic [64:0] two_r; logic rndup;
          rrem  = S[63:0];                        // corrected remainder (< mb)
          two_r = {rrem, 1'b0};
          rndup = rprem1 && !rc2 &&
                  ((two_r > {1'b0, rmb}) || ((two_r == {1'b0, rmb}) && qacc[0]));
          if (rndup) begin r = rmb - rrem; s_eff = ~rsa; q_eff = qacc[63:0] + 64'd1; end
          else       begin r = rrem;       s_eff =  rsa; q_eff = qacc[63:0];          end
          if (r==64'd0) begin
            result_q <= {3'b000, s_eff, 15'd0, 64'd0};       // signed zero
          end else begin
            lz   = rem_clz64(r);
            mant = r << lz;
            e    = reb - {10'd0, lz};
            if (e <= 0) begin
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
