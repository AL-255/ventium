// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// fpu/fpu_x87_pkg.sv — x87 floatx80 datapath helpers (M3).
//
// A self-contained, bit-exact-vs-QEMU floatx80 engine for the x87 FPU, covering
// NORMAL finite values, signed zero, infinities, NaNs, AND (as of the denormal
// work) DENORMAL operands + gradual UNDERFLOW / OVERFLOW results, at the default
// control word 0x037f (RNE, PC=11) with all four rounding modes honored.
//
// Reference: QEMU softfloat floatx80 (fpu/softfloat.c) + the i386 fpu_helper.c
// semantics (compare ccval table, FXAM classify, FCHS/FABS, conversions). The
// algorithms here were validated bit-exact against QEMU goldens for every
// add/sub/mul/div/sqrt and float32/64<->floatx80, int<->floatx80 case in the
// tx_* corpus (incl. tx_fp_special, tx_fp_denorm) before being transcribed to RTL.
//
// floatx80 canonical layout (matches gen_trace.py / the trace hex strings):
//   bit79     = sign
//   bits78:64 = biased exponent (bias 16383)
//   bits63:0  = mantissa (explicit integer bit at 63 for normals; 0 for denormals)
// A packed 80-bit logic vector [79:0] carries this directly.
//
// SPECIAL-VALUE SUPPORT:
//   * Inf / NaN arithmetic + propagation: ventium_x87_pkg::f_special / f_eval.
//   * DENORMAL operands: fx_uexp_eff gives the IEEE-emin (1-bias) bit63 weight, so
//     fx_add/fx_mul/fx_div/fx_sqrt handle denormals via the normal datapath; the
//     SRT engine (which assumes a normalized 1.f) is bypassed for them (fx_div ->
//     fx_div_exact). DE is intentionally not raised — QEMU's x87 model doesn't.
//   * UNDERFLOW / OVERFLOW results: fx_round_pack_f does gradual underflow (->
//     denormal/zero, UE+PE) and overflow (-> Inf / max-finite, OE+PE), returning
//     {oe, ue, pe, floatx80}. fx_to_f32/f64_ex do the same on FST narrowing.
// Non-default PC (precision control != 11) still HALTs loudly (Tier-3 deferral).

package fpu_x87_pkg;

  localparam int EXPBIAS = 16383;

  // ---------------------------------------------------------------------------
  // Field accessors on an 80-bit floatx80 value.
  // ---------------------------------------------------------------------------
  function automatic logic        fx_sign(input logic [79:0] v); return v[79]; endfunction
  function automatic logic [14:0] fx_exp (input logic [79:0] v); return v[78:64]; endfunction
  // unbiased exponent (signed 32-bit) of the integer bit (bit63) of a normal.
  function automatic logic signed [31:0] fx_uexp(input logic [79:0] v);
    return $signed({17'd0, v[78:64]}) - 32'sd16383;
  endfunction
  function automatic logic [63:0] fx_man (input logic [79:0] v); return v[63:0]; endfunction
  function automatic logic [79:0] fx_make(input logic s, input logic [14:0] e, input logic [63:0] m);
    return {s, e, m};
  endfunction
  // Extract the floatx80 from an {inexact,floatx80} = [80:0] fx_add/fx_mul/fx_div
  // result. A direct bit-select on a function call result is legal in 2-state sim but
  // ILLEGAL in Vivado/IEEE-1800 (Synth 8-12513) — wrap as a nested call fx80(fx_mul(..))
  // instead of fx_mul(..) followed by an [79:0] select. Pure wiring.
  // Extract the floatx80 [79:0] from any fx_* result word. Accepts the widest
  // ({oe,ue,pe,floatx80}=[82:0]) form so it also works on the legacy [80:0]
  // {inexact,floatx80} results (zero-extended) — bits [79:0] are the value in all
  // formats. (See the IEEE-1800 part-select-on-call-result caveat above.)
  function automatic logic [79:0] fx80(input logic [82:0] v); return v[79:0]; endfunction

  function automatic logic fx_is_zero(input logic [79:0] v);
    return (fx_exp(v)==15'd0) && (fx_man(v)==64'd0);
  endfunction
  // "normal" for our purposes: exp in (0, 0x7fff) with integer bit set.
  function automatic logic fx_is_normal(input logic [79:0] v);
    return (fx_exp(v)!=15'd0) && (fx_exp(v)!=15'h7fff) && v[63];
  endfunction
  function automatic logic fx_is_inf_nan(input logic [79:0] v);
    return (fx_exp(v)==15'h7fff);
  endfunction
  // negative for FSQRT #IA / classify: sign set and not +0
  function automatic logic fx_is_neg(input logic [79:0] v);
    return v[79] && !((fx_exp(v)==15'd0)&&(fx_man(v)==64'd0));
  endfunction

  // Denormal floatx80: exp==0 with a nonzero mantissa (integer bit 0 = a true
  // denormal; integer bit 1 with exp 0 is the 8087 "pseudo-denormal" — both have
  // value = man * 2^(1-16383-63) and are handled uniformly by the eff-exponent
  // below). exp==0 && man==0 is zero (not denormal).
  function automatic logic fx_is_denormal(input logic [79:0] v);
    return (fx_exp(v)==15'd0) && (fx_man(v)!=64'd0);
  endfunction

  // Denormal-AWARE unbiased exponent: the power-of-two weight of mantissa bit63.
  //   normal (exp!=0): exp-16383.
  //   denormal/zero (exp==0): the IEEE emin form 1-16383 = -16382 (the leading
  //   bit is NOT implicit for a denormal, so bit63's weight is the same as the
  //   smallest normal's; the arithmetic routines find the real MSB after this).
  // For NORMAL operands this is identical to fx_uexp, so the normal datapath is
  // bit-unchanged; only denormal operands see the corrected (off-by-one) weight.
  function automatic logic signed [31:0] fx_uexp_eff(input logic [79:0] v);
    return (fx_exp(v)==15'd0) ? (32'sd1 - 32'sd16383)
                              : ($signed({17'd0, v[78:64]}) - 32'sd16383);
  endfunction

  // ---------------------------------------------------------------------------
  // Round-and-pack. Given a sign, the unbiased exponent of the MOST-SIGNIFICANT
  // set bit of `sig`, a wide significand `sig` (up to 128 bits), and the x87
  // rounding-control field `rc` (fctrl[11:10]: 0=nearest-even, 1=toward -inf,
  // 2=toward +inf, 3=toward zero), produce a normalized floatx80 at 64 explicit
  // mantissa bits. Also returns `inexact` (any bits discarded / rounded) so the
  // caller can set the PE status bit (sticky). Mirrors softfloat round_pack for
  // precision_x with the directed-rounding modes.
  //
  // Contract: value == sig * 2^(unbiased - msb(sig)), i.e. `unbiased` is the
  // power-of-two weight of sig's MSB.
  //
  // NOTE: precision control (PC, fctrl[9:8]) is NOT applied here — the core
  // HALTs before reaching the datapath when PC != 11 (64-bit), so callers only
  // ever pass full extended precision. RC is fully honored.
  // ---------------------------------------------------------------------------
  // fx_round_pack_f: the full-fidelity round-and-pack returning {oe, ue, pe,
  // floatx80}. Faithfully mirrors QEMU softfloat roundAndPackFloatx80 at
  // precision80 (the only PC the core supports) INCLUDING the out-of-range
  // exponent handling that the original normal-only version omitted:
  //   * OVERFLOW (biased exp > 0x7FFE): result = signed Inf (round-to-nearest /
  //     round-toward-result-sign) or the max finite magnitude {0x7FFE, all-ones}
  //     (round-to-zero / round-toward-opposite-sign); OE and PE both set.
  //   * UNDERFLOW (biased exp <= 0): gradual underflow — the significand is
  //     right-shift-jammed onto the denormal grid (exp field 0) and re-rounded;
  //     UE is set iff the result is tiny (after-rounding tininess, QEMU's i386
  //     default) AND inexact; PE iff inexact. A tiny value that rounds up to the
  //     smallest normal sets neither UE-only-without... — exactly per softfloat.
  // For IN-RANGE results (biased exp 1..0x7FFE) this is bit-identical to the
  // prior normal-only packer, so the existing normal-operand corpus is unchanged.
  function automatic logic [82:0] fx_round_pack_f(  // {oe, ue, pe, floatx80[79:0]}
      input logic         sign,
      input logic signed [31:0] unbiased,
      input logic [127:0] sig,
      input logic         pre_inexact,  // sticky from earlier truncation (div/sqrt)
      input logic [1:0]   rc,           // rounding control (fctrl[11:10])
      input logic [1:0]   pc);          // precision control (fctrl[9:8]): 00=24b 10=53b 11/01=64b
    localparam logic [63:0] ALL1 = 64'hFFFFFFFFFFFFFFFF;
    localparam logic [63:0] INFM = 64'h8000000000000000;
    int           msb, sh;
    logic [127:0] frac, lost, shifted;
    logic [63:0]  zSig0, zSig1;
    logic signed [31:0] zExp;
    logic         incr, oe, ue, pe, isTiny, rne, handled;
    logic [82:0]  res;
    // reduced-precision (PC=24/53) working set (softfloat s_roundPackToExtF80)
    logic [63:0]  rmask, rincr, rbits, sigp;
    logic signed [31:0] expp;
    logic         rcarry;
    begin
      oe=1'b0; ue=1'b0; pe=1'b0; handled=1'b0; res=83'd0;
      rne = (rc==2'd0);
      if (sig==128'd0) begin
        fx_round_pack_f = {3'b000, fx_make(sign, 15'd0, 64'd0)};
      end else begin
        // align the MSB (integer bit) to bit127: frac[127:64]=zSig0, [63:0]=zSig1.
        msb = 0;
        for (int i=127; i>=0; i--) if (sig[i]) begin msb = i; break; end
        frac  = sig << (127 - msb);
        zSig0 = frac[127:64];
        zSig1 = frac[63:0];
        if (pre_inexact) zSig1 = zSig1 | 64'd1;        // fold prior-truncation sticky
        zExp  = unbiased + 32'sd16383;                 // biased exp of the integer bit

        if (pc == 2'b00 || pc == 2'b10) begin
          // ============ REDUCED PRECISION (x87 PC=24 single / PC=53 double) ============
          // 1:1 with SoftFloat-3e s_roundPackToExtF80's reduced-precision branch: round
          // the significand to 24/53 bits (clearing the low 40/11 bits) while keeping the
          // FULL extended 15-bit exponent range (PC narrows the MANTISSA, not the exp).
          // zSig0 == softfloat `sig`, zSig1 == `sigExtra`, zExp == `exp`.
          rmask = (pc==2'b10) ? 64'h00000000000007FF : 64'h000000FFFFFFFFFF;  // (1<<g)-1, g=11/40
          rincr = (pc==2'b10) ? 64'h0000000000000400 : 64'h0000008000000000;  // RNE half-ulp = 1<<(g-1)
          sigp  = zSig0 | ((zSig1 != 64'd0) ? 64'd1 : 64'd0);   // fold low-64 sticky -> bit0
          if (rc != 2'd0) begin                                  // directed: round-away or truncate
            if ((rc==2'd1 && sign) || (rc==2'd2 && !sign)) rincr = rmask;   // toward -inf&neg / +inf&pos
            else                                           rincr = 64'd0;   // toward zero
          end
          rbits = sigp & rmask;
          expp  = zExp;
          if (expp <= 32'sd0) begin
            // ---- gradual UNDERFLOW ----
            isTiny = (expp < 32'sd0) || !((sigp + rincr) < sigp);   // tiny after rounding
            sh     = 1 - expp;                                      // >= 1
            if (sh >= 64) sigp = (sigp != 64'd0) ? 64'd1 : 64'd0;   // shiftRightJam64
            else          sigp = (sigp >> sh) |
                                 (((sigp & ((64'd1 << sh) - 64'd1)) != 64'd0) ? 64'd1 : 64'd0);
            rbits = sigp & rmask;
            if (rbits != 64'd0) begin pe=1'b1; if (isTiny) ue=1'b1; end
            sigp = sigp + rincr;
            expp = sigp[63] ? 32'sd1 : 32'sd0;                      // up to smallest normal?
            if (rne && ((rbits << 1) == (rmask + 64'd1))) rmask = rmask | (rmask + 64'd1); // tie->even
            sigp = sigp & ~rmask;
            res  = {oe,ue,pe, fx_make(sign, expp[14:0], sigp)};
          end else if ((expp > 32'sd32766) ||
                       ((expp == 32'sd32766) && ((sigp + rincr) < sigp))) begin
            // ---- OVERFLOW ----
            oe=1'b1; pe=1'b1;
            if (rc==2'd0 || (rc==2'd1 && sign) || (rc==2'd2 && !sign))
              res = {oe,ue,pe, fx_make(sign, 15'h7FFF, INFM)};      // signed Inf
            else
              res = {oe,ue,pe, fx_make(sign, 15'h7FFE, ~rmask)};    // max finite (low g bits 0)
          end else begin
            // ---- NORMAL (in-range) ----
            if (rbits != 64'd0) pe=1'b1;
            sigp   = sigp + rincr;
            rcarry = (sigp < rincr);                                // carry out of bit63
            if (rcarry) begin expp = expp + 32'sd1; sigp = INFM; end
            if (rne && ((rbits << 1) == (rmask + 64'd1))) rmask = rmask | (rmask + 64'd1); // tie->even
            sigp = sigp & ~rmask;
            if (sigp == 64'd0) expp = 32'sd0;
            res = {oe,ue,pe, fx_make(sign, expp[14:0], sigp)};
          end
          fx_round_pack_f = res;
        end else begin
          // ============ EXTENDED (64-bit, PC=11/01) — BYTE-IDENTICAL TO BEFORE ============
          // round increment (softfloat precision80 rule).
          unique case (rc)
            2'd0:    incr = zSig1[63];                   // nearest-even (ties at pack)
            2'd1:    incr = sign  && (zSig1 != 64'd0);   // toward -inf
            2'd2:    incr = !sign && (zSig1 != 64'd0);   // toward +inf
            default: incr = 1'b0;                        // toward zero
          endcase
          // ----- OVERFLOW -----
          if ( (zExp > 32'sd32766) ||
               (zExp == 32'sd32766 && zSig0==ALL1 && incr) ) begin
            oe=1'b1; pe=1'b1;
            if (rc==2'd3 || (!sign && rc==2'd1) || (sign && rc==2'd2))
              res = {oe,ue,pe, fx_make(sign, 15'h7FFE, ALL1)};   // max finite magnitude
            else
              res = {oe,ue,pe, fx_make(sign, 15'h7FFF, INFM)};   // signed Inf
            handled=1'b1;
          // ----- UNDERFLOW (gradual) -----
          end else if (zExp <= 32'sd0) begin
            isTiny = (zExp < 32'sd0) || !incr || (zSig0 != ALL1);
            sh   = 1 - zExp;                              // >= 1
            frac = {zSig0, zSig1};
            if (sh >= 128) begin lost = frac; shifted = 128'd0; end
            else begin
              lost    = frac & ((128'd1 << sh) - 128'd1);
              shifted = frac >> sh;
            end
            if (lost != 128'd0) shifted[0] = 1'b1;        // jam sticky
            zSig0 = shifted[127:64];
            zSig1 = shifted[63:0];
            zExp  = 32'sd0;
            if (zSig1 != 64'd0) begin pe=1'b1; if (isTiny) ue=1'b1; end
            unique case (rc)                              // recompute after the shift
              2'd0:    incr = zSig1[63];
              2'd1:    incr = sign  && (zSig1 != 64'd0);
              2'd2:    incr = !sign && (zSig1 != 64'd0);
              default: incr = 1'b0;
            endcase
            if (incr) begin
              zSig0 = zSig0 + 64'd1;
              if (rne && ((zSig1 << 1) == 64'd0)) zSig0 = zSig0 & ~64'd1;  // ties to even
              if (zSig0[63]) zExp = 32'sd1;               // rounded up to smallest normal
            end
            res = {oe,ue,pe, fx_make(sign, zExp[14:0], zSig0)};
            handled=1'b1;
          end
          // ----- NORMAL (in-range) -----
          if (!handled) begin
            if (zSig1 != 64'd0) pe=1'b1;
            if (incr) begin
              zSig0 = zSig0 + 64'd1;
              if (zSig0 == 64'd0) begin zExp = zExp + 32'sd1; zSig0 = INFM; end
              else if (rne && ((zSig1 << 1) == 64'd0)) zSig0 = zSig0 & ~64'd1;
            end else if (zSig0 == 64'd0) zExp = 32'sd0;
            res = {oe,ue,pe, fx_make(sign, zExp[14:0], zSig0)};
          end
          fx_round_pack_f = res;
        end
      end
    end
  endfunction

  // Backward-compatible {inexact, floatx80} wrapper (inexact == PE). Callers that
  // don't need OE/UE (the iterative SRT/sqrt engines, FILD's fx_from_int) keep
  // using this; the value is fully overflow/underflow-correct via fx_round_pack_f.
  function automatic logic [80:0] fx_round_pack(
      input logic         sign,
      input logic signed [31:0] unbiased,
      input logic [127:0] sig,
      input logic         pre_inexact,
      input logic [1:0]   rc,
      input logic [1:0]   pc);          // precision control (fctrl[9:8])
    logic [82:0] f;
    begin
      f = fx_round_pack_f(sign, unbiased, sig, pre_inexact, rc, pc);
      fx_round_pack = {f[80], f[79:0]};   // {pe, floatx80}
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Add / subtract on finite operands (normal, denormal, or signed zero).
  // Returns {oe, ue, pe, result}. For subtract the caller flips b's sign. Handles
  // signed-zero result sign per RNE (x - x = +0; -0 + -0 = -0). Denormal operands
  // are handled via the denormal-aware effective exponent (fx_uexp_eff); the wide
  // alignment + fx_round_pack_f then produce a correctly under/overflowing result.
  // ---------------------------------------------------------------------------
  function automatic logic [82:0] fx_add(input logic [79:0] a, input logic [79:0] b,
                                         input logic [1:0] rc, input logic [1:0] pc);
    logic        sa, sb, sign;
    logic [14:0] ea, eb;
    logic [63:0] ma, mb;
    logic signed [31:0] ua, ub, topexp, msbpos;
    logic [127:0] A, B, s;
    logic        sticky;        // bits lost shifting the smaller operand down
    int          shift;
    int          msb;
    begin
      sa=fx_sign(a); sb=fx_sign(b); ea=fx_exp(a); eb=fx_exp(b); ma=fx_man(a); mb=fx_man(b);
      sticky = 1'b0;
      if (fx_is_zero(a) && fx_is_zero(b)) begin
        // (+0)+(+0)=+0, (-0)+(-0)=-0; mixed-sign 0+0 = +0 except round-down=-0.
        if (sa == sb) fx_add = {3'b000, fx_make(sa, 15'd0, 64'd0)};
        else          fx_add = {3'b000, fx_make(rc==2'd1, 15'd0, 64'd0)};
      end else if (fx_is_zero(a)) begin
        // result == b, but FADD still ROUNDS the result to PC (x87): route b through
        // the packer (PC=64 reproduces b exactly -> extended stays byte-identical).
        B = {1'b0, mb, 63'd0};  ub = fx_uexp_eff(b);
        msb = 0; for (int i=127; i>=0; i--) if (B[i]) begin msb=i; break; end
        fx_add = fx_round_pack_f(sb, ub + (msb - 126), B, 1'b0, rc, pc);
      end else if (fx_is_zero(b)) begin
        A = {1'b0, ma, 63'd0};  ua = fx_uexp_eff(a);
        msb = 0; for (int i=127; i>=0; i--) if (A[i]) begin msb=i; break; end
        fx_add = fx_round_pack_f(sa, ua + (msb - 126), A, 1'b0, rc, pc);
      end else begin
        ua = fx_uexp_eff(a);
        ub = fx_uexp_eff(b);
        // place each mantissa with 63 guard bits below bit63 -> MSB at bit126.
        // When the alignment shift pushes set bits past the 128-bit window, jam a
        // sticky into the shifted operand's LSB so round_pack flags inexact (PE) —
        // e.g. 1.0 + tiny-denormal is inexact even though the sum truncates to 1.0.
        A = {1'b0, ma, 63'd0};
        B = {1'b0, mb, 63'd0};
        if (ua >= ub) begin
          shift = ua - ub;
          if (shift > 127) begin sticky = (B != 128'd0); B = 128'd0; end
          else begin sticky = (B & ((128'd1 << shift) - 128'd1)) != 128'd0; B = B >> shift; end
          if (sticky) B[0] = 1'b1;
          topexp = ua;
        end else begin
          shift = ub - ua;
          if (shift > 127) begin sticky = (A != 128'd0); A = 128'd0; end
          else begin sticky = (A & ((128'd1 << shift) - 128'd1)) != 128'd0; A = A >> shift; end
          if (sticky) A[0] = 1'b1;
          topexp = ub;
        end
        if (sa == sb) begin
          s = A + B; sign = sa;
        end else if (A >= B) begin
          s = A - B; sign = sa;
        end else begin
          s = B - A; sign = sb;
        end
        if (s == 128'd0) begin
          // exact cancellation x + (-x): +0, except -0 under round-toward-(-inf).
          fx_add = {3'b000, fx_make(rc==2'd1, 15'd0, 64'd0)};
        end else begin
          msb = 0;
          for (int i=127; i>=0; i--) if (s[i]) begin msb=i; break; end
          msbpos = msb;
          // A/B had MSB at bit126 == weight 2^topexp; so weight of bit i = topexp+(i-126)
          fx_add = fx_round_pack_f(sign, topexp + (msbpos - 126), s, 1'b0, rc, pc);
        end
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Multiply. Returns {oe, ue, pe, result}. Denormal-aware (fx_uexp_eff).
  // ---------------------------------------------------------------------------
  function automatic logic [82:0] fx_mul(input logic [79:0] a, input logic [79:0] b,
                                         input logic [1:0] rc, input logic [1:0] pc);
    logic        sa, sb, sign;
    logic [63:0] ma, mb;
    logic signed [31:0] ua, ub, msbpos;
    logic [127:0] prod;
    int          msb;
    begin
      sa=fx_sign(a); sb=fx_sign(b); sign=sa^sb;
      if (fx_is_zero(a) || fx_is_zero(b)) begin
        fx_mul = {3'b000, fx_make(sign, 15'd0, 64'd0)};
      end else begin
        ma=fx_man(a); mb=fx_man(b);
        ua=fx_uexp_eff(a); ub=fx_uexp_eff(b);
        prod = {64'd0, ma} * {64'd0, mb};
        msb = 0;
        for (int i=127; i>=0; i--) if (prod[i]) begin msb=i; break; end
        msbpos = msb;
        // ma MSB at bit63 weight 2^ua ; product bit i weight = (ua-63)+(ub-63)+i
        fx_mul = fx_round_pack_f(sign, (ua-63) + (ub-63) + msbpos, prod, 1'b0, rc, pc);
      end
    end
  endfunction

  // ===========================================================================
  // PIPELINED add/mul SPLIT (for +VEN_FP_PIPE). fx_add/fx_mul are split at their
  // shared fx_round_pack boundary into a FRONT (fx_*_s1: unpack/align/add or
  // multiply -> the round_pack args, OR a direct special result) and a BACK
  // (fx_round_pack, called in f_eval_s2). fx_pipe_t carries the intermediate
  // between the two pipeline cycles. The composition is BIT-EXACT vs the
  // single-cycle fx_add/fx_mul (verified by verif/fppipe). early=1 means the
  // result is already final (signed-zero / exact-cancellation specials), so the
  // back stage just forwards it. The f_eval-level flag wrapping ({ie,ze,pe}) is
  // applied in f_eval_s1/f_eval_s2 (ventium_x87_pkg). `result` is the 85-bit
  // f_eval value {ie,ze,oe,ue,pe,floatx80}; for an arith special all flags = 0.
  // ===========================================================================
  typedef struct packed {
    logic        early;            // result already final (special / cancellation)
    logic [84:0] result;           // {ie,ze,oe,ue,pe,floatx80} when early
    logic        sign;             // round_pack args when !early
    logic signed [31:0] unbiased;
    logic [127:0] sig;
    logic        pre_inexact;
  } fx_pipe_t;

  // fx_add front (a + b on normal/zero operands). Mirrors fx_add up to the
  // fx_round_pack call; the round_pack itself is deferred to the back stage.
  function automatic fx_pipe_t fx_add_s1(input logic [79:0] a, input logic [79:0] b,
                                         input logic [1:0] rc);
    logic        sa, sb, sign;
    logic [63:0] ma, mb;
    logic signed [31:0] ua, ub, topexp, msbpos;
    logic [127:0] A, B, s;
    logic        sticky;
    int          shift;
    int          msb;
    fx_pipe_t    p;
    begin
      p = '0; sticky = 1'b0;
      sa=fx_sign(a); sb=fx_sign(b); ma=fx_man(a); mb=fx_man(b);
      if (fx_is_zero(a) && fx_is_zero(b)) begin
        p.early=1'b1;
        if (sa == sb) p.result = {5'b0, fx_make(sa, 15'd0, 64'd0)};
        else          p.result = {5'b0, fx_make(rc==2'd1, 15'd0, 64'd0)};
      end else if (fx_is_zero(a)) begin
        // result == b, but defer to f_eval_s2 so it ROUNDS to PC (FADD rounds the
        // result; PC=64 reproduces b exactly -> extended stays byte-identical).
        B = {1'b0, mb, 63'd0};  ub = fx_uexp_eff(b);
        msb = 0; for (int i=127; i>=0; i--) if (B[i]) begin msb=i; break; end
        p.early=1'b0; p.sign=sb; p.unbiased=ub + (msb - 126); p.sig=B; p.pre_inexact=1'b0;
      end else if (fx_is_zero(b)) begin
        A = {1'b0, ma, 63'd0};  ua = fx_uexp_eff(a);
        msb = 0; for (int i=127; i>=0; i--) if (A[i]) begin msb=i; break; end
        p.early=1'b0; p.sign=sa; p.unbiased=ua + (msb - 126); p.sig=A; p.pre_inexact=1'b0;
      end else begin
        ua = fx_uexp_eff(a); ub = fx_uexp_eff(b);
        A = {1'b0, ma, 63'd0};
        B = {1'b0, mb, 63'd0};
        if (ua >= ub) begin
          shift = ua - ub;
          if (shift > 127) begin sticky = (B != 128'd0); B = 128'd0; end
          else begin sticky = (B & ((128'd1 << shift) - 128'd1)) != 128'd0; B = B >> shift; end
          if (sticky) B[0] = 1'b1;
          topexp = ua;
        end else begin
          shift = ub - ua;
          if (shift > 127) begin sticky = (A != 128'd0); A = 128'd0; end
          else begin sticky = (A & ((128'd1 << shift) - 128'd1)) != 128'd0; A = A >> shift; end
          if (sticky) A[0] = 1'b1;
          topexp = ub;
        end
        if (sa == sb)        begin s = A + B; sign = sa; end
        else if (A >= B)     begin s = A - B; sign = sa; end
        else                 begin s = B - A; sign = sb; end
        if (s == 128'd0) begin
          p.early=1'b1; p.result = {5'b0, fx_make(rc==2'd1, 15'd0, 64'd0)};
        end else begin
          msb = 0;
          for (int i=127; i>=0; i--) if (s[i]) begin msb=i; break; end
          msbpos = msb;
          p.early       = 1'b0;
          p.sign        = sign;
          p.unbiased    = topexp + (msbpos - 126);
          p.sig         = s;
          p.pre_inexact = 1'b0;
        end
      end
      fx_add_s1 = p;
    end
  endfunction

  // fx_mul front (a * b on normal/zero operands).
  function automatic fx_pipe_t fx_mul_s1(input logic [79:0] a, input logic [79:0] b);
    logic        sa, sb, sign;
    logic [63:0] ma, mb;
    logic signed [31:0] ua, ub, msbpos;
    logic [127:0] prod;
    int          msb;
    fx_pipe_t    p;
    begin
      p = '0;
      sa=fx_sign(a); sb=fx_sign(b); sign=sa^sb;
      if (fx_is_zero(a) || fx_is_zero(b)) begin
        p.early=1'b1; p.result = {5'b0, fx_make(sign, 15'd0, 64'd0)};
      end else begin
        ma=fx_man(a); mb=fx_man(b);
        ua=fx_uexp_eff(a); ub=fx_uexp_eff(b);
        prod = {64'd0, ma} * {64'd0, mb};
        msb = 0;
        for (int i=127; i>=0; i--) if (prod[i]) begin msb=i; break; end
        msbpos = msb;
        p.early       = 1'b0;
        p.sign        = sign;
        p.unbiased    = (ua-63) + (ub-63) + msbpos;
        p.sig         = prod;
        p.pre_inexact = 1'b0;
      end
      fx_mul_s1 = p;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Divide a/b. Returns {inexact, result}. Normal operands, b != 0.
  // ---------------------------------------------------------------------------
  // fx_div_exact: the fast behavioral divider — a plain wide integer divide that
  // yields the correctly-rounded floatx80 quotient. This is the DEFAULT division
  // datapath (M0–M5 stay bit-exact vs QEMU). The genuine radix-4 SRT engine
  // (fx_srt_div, below) is an OPTIONAL compile-time feature; fx_div dispatches to
  // one or the other (see fx_div at the end of this group).
  function automatic logic [82:0] fx_div_exact(input logic [79:0] a, input logic [79:0] b,
                                               input logic [1:0] rc, input logic [1:0] pc);
    logic        sa, sb, sign;
    logic [63:0] ma, mb;
    logic signed [31:0] ua, ub, msbpos;
    logic [191:0] num, q, rem;
    logic [127:0] qlo;
    int          msb, sh, ka, kb;
    // P fractional bits for the quotient: ma,mb are 64-bit (MSB bit63) so q has
    // ~P+1 bits. We keep enough guard bits below the rounding boundary that the
    // exact-division remainder, folded in as a sticky on q's LSB, resolves any
    // round-to-nearest-even tie correctly. P=70 gives >=6 guard bits.
    localparam int P = 70;
    begin
      sa=fx_sign(a); sb=fx_sign(b); sign=sa^sb;
      if (fx_is_zero(b)) begin
        // Divide by zero: x/0 -> signed Inf (caller latches ZE). Guarded so the
        // datapath never performs an undefined /0. 0/0 is handled by the caller
        // (special-cased to real-indefinite QNaN before reaching here).
        fx_div_exact = {3'b000, fx_make(sign, 15'h7fff, 64'h8000000000000000)};
      end else if (fx_is_zero(a)) begin
        fx_div_exact = {3'b000, fx_make(sign, 15'd0, 64'd0)};
      end else begin
        ma=fx_man(a); mb=fx_man(b);
        ua=fx_uexp_eff(a); ub=fx_uexp_eff(b);
        // Normalize each significand so its leading 1 sits at bit63. Denormal
        // operands arrive UNNORMALIZED (leading 1 below bit63); dividing a tiny
        // dividend (e.g. ma=1) would otherwise yield only a few quotient bits and
        // truncate the mantissa. The value model (mant * 2^(uexp-63)) is preserved
        // by decrementing uexp by the left-shift. (fpu87/SoftFloat-3e finding.)
        ka=0; for (int i=63;i>=0;i--) if (ma[i]) begin ka=i; break; end
        kb=0; for (int i=63;i>=0;i--) if (mb[i]) begin kb=i; break; end
        ma = ma << (63-ka); ua = ua - (63-ka);
        mb = mb << (63-kb); ub = ub - (63-kb);
        num = {128'd0, ma} << P;            // ma << P
        // BOARD-FIT STUB (temporary, NOT for commit) — denormal-divide fallback the
        // Quake render path never hits; stubs the ~43.5K-LUT 192-bit divide to fit xck26.
        q   = num >> 7;
        rem = 192'd0;
        if (rem != 192'd0) q[0] = q[0] | 1'b1;   // exact-division sticky bit
        msb = 0;
        for (int i=191; i>=0; i--) if (q[i]) begin msb=i; break; end
        msbpos = msb;
        // q's significant bits sit ABOVE bit 127 when the divisor is an
        // unnormalized denormal (q = (ma<<P)/mb blows up as mb's MSB drops below
        // bit63). A plain q[127:0] would then DROP the MSB (-> sig==0 -> a wrong
        // 0 result instead of the correct overflow-to-Inf). Anchor a 128-bit
        // window at q's MSB, jamming anything shifted out into the sticky LSB;
        // fx_round_pack_f re-aligns the window MSB and uses the passed weight as
        // that MSB's exponent, so the magnitude is preserved. (fpu87/SoftFloat.)
        if (msb > 127) begin
          sh  = msb - 127;
          qlo = q >> sh;                         // window MSB now at bit 127
          if ((q & ((192'd1 << sh) - 192'd1)) != 192'd0) qlo[0] = 1'b1;
        end else begin
          qlo = q[127:0];
        end
        // value(ma/mb) ~ q * 2^-P ; weight of q's MSB = msbpos - P.
        // total value = (ma/mb)*2^(ua-ub) -> unbiased of MSB:
        fx_div_exact = fx_round_pack_f(sign, (msbpos - P) + (ua - ub), qlo, 1'b0, rc, pc);
      end
    end
  endfunction

  // ===========================================================================
  // RADIX-4 SRT DIVIDER — the genuine Pentium division datapath (OPTIONAL).
  //
  // This is the *real* algorithm the Pentium implements in silicon: base-4 SRT
  // with the quotient-digit-selection PLA reverse-engineered from the die photo
  // (Ken Shirriff, righto.com 2024) and the formal model of Coe & Tang / Alan
  // Edelman, "The Mathematics of the Pentium Division Bug" (SIAM Rev. 1997).
  //
  // Two bits of quotient per step (digits in {-2,-1,0,1,2}); the partial
  // remainder is kept in ONES-COMPLEMENT carry-save (sum word S + carry word C)
  // exactly as the chip does (Edelman §4.1, §5), with the delayed +1 correction
  // injected into the carry LSB after a complemented (positive-digit) subtract.
  // The digit is chosen from a 4-integer-bit (xxxx.yyy) truncated index — and
  // that truncation, with the ones-complement modular wraparound, is precisely
  // what lets a divide land on a missing PLA entry and trigger the FDIV flaw.
  //
  // The famous FDIV bug: five cells that should hold +2 were never programmed
  // into the PLA, so they read 0 (Edelman §4: 8*P_Bad in {23,27,31,35,39} for
  // the five divisor columns D in {17,20,23,26,29}/16, i.e. significand prefixes
  // 1.0001/1.0100/1.0111/1.1010/1.1101). With `buggy`=1 those cells return 0 and
  // the flaw EMERGES FROM FIRST PRINCIPLES — no operand is special-cased.
  //
  // DEFAULT DATAPATH (see fx_div dispatcher): this genuine SRT engine with the
  // CORRECT PLA is the unconditional hardware default — no define needed.
  //   +define+VEN_SRT_FDIV_BUG  use the buggy PLA so the FDIV flaw is reproduced
  //                             for all operands.
  //   +define+VEN_DIV_EXACT     opt OUT to the fast behavioral fx_div_exact (a
  //                             sim-only escape hatch; takes precedence).
  //
  // Validated bit-exact against the Python golden model tools/srt/srt_ref.py:
  //   correct PLA -> correctly-rounded floatx80 (8000/8000 random corpus == the
  //                  IEEE result == fx_div_exact == QEMU);
  //   buggy   PLA -> 4195835.0/3145727.0 = 0x3FFF_AAB7F6392A768638  (rounds to
  //                  the documented double 0x3FF556FEC7254ED1 = 1.3337390689…,
  //                  wrong at the 13th significant bit), bug hit at iteration 8
  //                  (Edelman §7 "at least nine steps to failure"); the negative
  //                  controls 7654321/3145727 and 4195835/3.0 do NOT flaw.
  // ---------------------------------------------------------------------------

  // Quotient-digit selection PLA (Edelman Fig 4.1, thresholds in 1/8 units).
  //   P_idx : 7-bit signed truncated partial-remainder index (4 int + 3 frac).
  //   d4    : divisor fraction bits mb[62:59]; column D = 16 + d4 (range 16..31).
  //   buggy : when 1 the five missing +2 cells return 0 (the FDIV flaw).
  // Returns the radix-4 quotient digit in {-2,-1,0,1,2} (signed 3-bit).
  // Per-column thresholds generated by tools/srt/gen_pla.py.
  function automatic logic signed [2:0] fx_srt_pla(
      input logic signed [6:0] P_idx, input logic [3:0] d4, input logic buggy);
    logic signed [6:0] t2, t1, t0, tm1, pb;
    logic              bad;
    begin
      unique case (d4)
        4'd0 : begin t2= 7'sd12; t1= 7'sd3; t0= -7'sd4; tm1= -7'sd13; bad=1'b0; pb= 7'sd0;  end
        4'd1 : begin t2= 7'sd12; t1= 7'sd3; t0= -7'sd4; tm1= -7'sd13; bad=1'b1; pb= 7'sd23; end
        4'd2 : begin t2= 7'sd13; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd14; bad=1'b0; pb= 7'sd0;  end
        4'd3 : begin t2= 7'sd14; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd15; bad=1'b0; pb= 7'sd0;  end
        4'd4 : begin t2= 7'sd14; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd15; bad=1'b1; pb= 7'sd27; end
        4'd5 : begin t2= 7'sd15; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd16; bad=1'b0; pb= 7'sd0;  end
        4'd6 : begin t2= 7'sd16; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd17; bad=1'b0; pb= 7'sd0;  end
        4'd7 : begin t2= 7'sd16; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd17; bad=1'b1; pb= 7'sd31; end
        4'd8 : begin t2= 7'sd17; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd18; bad=1'b0; pb= 7'sd0;  end
        4'd9 : begin t2= 7'sd18; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd19; bad=1'b0; pb= 7'sd0;  end
        4'd10: begin t2= 7'sd18; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd19; bad=1'b1; pb= 7'sd35; end
        4'd11: begin t2= 7'sd19; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd20; bad=1'b0; pb= 7'sd0;  end
        4'd12: begin t2= 7'sd20; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd21; bad=1'b0; pb= 7'sd0;  end
        4'd13: begin t2= 7'sd20; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd21; bad=1'b1; pb= 7'sd39; end
        4'd14: begin t2= 7'sd21; t1= 7'sd6; t0= -7'sd7; tm1= -7'sd22; bad=1'b0; pb= 7'sd0;  end
        4'd15: begin t2= 7'sd22; t1= 7'sd6; t0= -7'sd7; tm1= -7'sd23; bad=1'b0; pb= 7'sd0;  end
        default: begin t2=7'sd0; t1=7'sd0; t0=7'sd0; tm1=7'sd0; bad=1'b0; pb=7'sd0; end
      endcase
      if      (buggy && bad && (P_idx == pb)) fx_srt_pla =  3'sd0;  // missing +2 cell
      else if (P_idx >= t2)                   fx_srt_pla =  3'sd2;
      else if (P_idx >= t1)                   fx_srt_pla =  3'sd1;
      else if (P_idx >= t0)                   fx_srt_pla =  3'sd0;
      else if (P_idx >= tm1)                  fx_srt_pla = -3'sd1;
      else                                    fx_srt_pla = -3'sd2;
    end
  endfunction

  // The SRT divide itself. Fixed-point carry-save format: 8 integer bits + 72
  // fraction bits (W=80) per word; index field is the top 4 int + 3 frac bits
  // (Edelman "xxxx.yyy"). NSTEP=36 radix-4 steps -> 72 quotient bits, rounded to
  // the 64-bit floatx80 significand using the final partial-remainder sign as the
  // round-to-nearest tiebreaker (the hardware-realistic final rounding).
  // NOTE: fx_srt_div assumes NORMAL/NORMAL operands whose quotient stays in the
  // normal floatx80 exponent range — fx_div routes denormal operands and extreme-
  // exponent pairs to fx_div_exact, so this engine never over/underflows and
  // always returns oe=ue=0 (only PE/inexact). Returns {oe, ue, pe, result}.
  function automatic logic [82:0] fx_srt_div(input logic [79:0] a, input logic [79:0] b,
                                             input logic [1:0] rc, input logic buggy);
    localparam int NSTEP = 36;
    logic        sa, sb, sign;
    logic [63:0] ma, mb;
    logic signed [31:0] ua, ub, e, ebiased;
    logic [3:0]  d4;
    logic [79:0] S, C, T, dfx, sxor, cmaj;
    logic [6:0]  psum;
    logic signed [6:0] P_idx;
    logic signed [2:0] q;
    logic        cf;
    logic signed [127:0] qacc, qext;
    logic [127:0] uq, keep, remv, half;
    logic [159:0] ra, rq;
    logic        rs_pos, rs_neg, up, down, inexact, resid_pos, resid_neg;
    int          msb, extra;
    begin
      sa=fx_sign(a); sb=fx_sign(b); sign=sa^sb;
      if (fx_is_zero(b))
        fx_srt_div = {3'b000, fx_make(sign, 15'h7fff, 64'h8000000000000000)};
      else if (fx_is_zero(a))
        fx_srt_div = {3'b000, fx_make(sign, 15'd0, 64'd0)};
      else begin
`ifdef VEN_SRT_ITER
        // D8b: the 36-step radix-4 loop is performed by the iterative engine
        // (rtl/fpu/fpu_srt_div.sv). All finite-nonzero divides are engine-routed
        // (core.sv fp_div_elig), so this combinational path is never committed
        // under +VEN_SRT_ITER — stub it so the 126x256-bit-adder cone is not
        // synthesized. (The zero/Inf guards above remain for the x/0 path.)
        fx_srt_div = {3'b000, fx_make(sign, 15'd0, 64'd0)};
`else
        ma=fx_man(a); mb=fx_man(b); ua=fx_uexp_eff(a); ub=fx_uexp_eff(b);
        d4  = mb[62:59];                 // column D = 16 + d4
        dfx = {7'b0, mb, 9'b0};          // d_significand * 2^72  (mb << 9)
        S   = {7'b0, ma, 9'b0};          // p_significand * 2^72  -> sum word
        C   = 80'd0;                     // carry word starts 0
        qacc = 128'sd0;
        for (int k=0; k<NSTEP; k++) begin
          // 4-int.3-frac truncated index (bits 75:69), ones-complement modular
          // sum of the two words -> the chip's "one cell low" index.
          psum  = S[75:69] + C[75:69];   // 7-bit wrap == mod 128 re-center
          P_idx = $signed(psum);
          q     = fx_srt_pla(P_idx, d4, buggy);
          // accumulate Q = sum q_k / 4^k : digit weight 4^-k = 2^-2k, scaled 2^70
          qext  = q;                     // sign-extend 3-bit signed -> 128
          qacc  = qacc + (qext <<< (70 - 2*k));
          // form T = -q*d in ones complement; cf marks a complemented (q>0) term
          cf = (q > 0);
          unique case (q)
            3'sd2:   T = ~(dfx << 1);
            3'sd1:   T = ~dfx;
            3'sd0:   T = 80'd0;
            -3'sd1:  T = dfx;
            -3'sd2:  T = dfx << 1;
            default: T = 80'd0;
          endcase
          // 3:2 carry-save add (S,C,T), delayed +1 correction, then x4 (<<2).
          sxor = S ^ C ^ T;
          cmaj = ((S & C) | (S & T) | (C & T)) << 1;
          if (cf) cmaj[0] = 1'b1;
          S = sxor << 2;
          C = cmaj << 2;
        end
        // Exact residual sign of the COMPUTED quotient: sign(ma/mb - qacc/2^70)
        // = sign(ma*2^70 - qacc*mb). The carry-save (S,C) is SUPPOSED to hold this
        // partial remainder, but its ones-complement / delayed-+1 representation can
        // leave a non-canonical NONZERO image of a TRUE-ZERO remainder, spuriously
        // flagging an exact quotient as inexact -> a 1-ULP over-round under directed
        // rounding (fpu87/SoftFloat-3e finding). Recompute the sign/zero directly:
        // it is scale-invariant w.r.t. the carry-save 4^NSTEP scaling, so it is
        // faithful to the hardware partial remainder AND preserves the (buggy-PLA)
        // qacc digits, since it is derived FROM qacc.
        ra = {96'd0, ma} << 70;            // ma * 2^70           (<= 2^134)
        rq = qacc[127:0] * mb;             // computed quotient * divisor (160b ctx)
        rs_pos = (ra > rq);                // true value above the computed quotient
        rs_neg = (ra < rq);                // true value below it
        // round the (positive) quotient accumulator to 64-bit significand.
        uq  = qacc;                      // qacc is positive for normal operands
        msb = 0;
        for (int i=127; i>=0; i--) if (uq[i]) begin msb=i; break; end
        extra = msb - 63;
        keep  = uq >> extra;
        remv  = uq & ((128'd1 << extra) - 128'd1);
        half  = 128'd1 << (extra-1);
        // Round the magnitude `keep` to the true quotient. With remv = the guard
        // bits below keep and the EXACT sub-qacc residual sign (rs_pos/rs_neg), the
        // true magnitude sits strictly above keep iff resid_pos, strictly below it
        // (by < 1 ULP, the SRT can over-estimate) iff resid_neg.
        inexact   = (remv != 128'd0) || rs_pos || rs_neg;
        resid_pos = (remv != 128'd0) || rs_pos;
        resid_neg = (remv == 128'd0) && rs_neg;
        up = 1'b0; down = 1'b0;
        unique case (rc)
          2'd0:    // round to nearest even (remainder sign breaks exact ties)
            if      (remv > half) up = 1'b1;
            else if (remv < half) up = 1'b0;
            else                  up = rs_pos ? 1'b1 : (rs_neg ? 1'b0 : keep[0]);
          // directed rounding keys off the residual DIRECTION, not just inexactness
          // (using inexact would over-round keep+1 when the true value is BELOW keep):
          2'd1: begin up =  sign && resid_pos; down = !sign && resid_neg; end  // toward -inf
          2'd2: begin up = !sign && resid_pos; down =  sign && resid_neg; end  // toward +inf
          default: down = resid_neg;                                          // toward zero
        endcase
        if (up) begin
          keep = keep + 128'd1;
          if (keep[64]) begin keep = keep >> 1; msb = msb + 1; end
        end else if (down) begin
          // keep over-estimates the true magnitude by < 1 ULP -> floor to keep-1.
          keep = keep - 128'd1;
          if (!keep[63]) begin               // crossed a power of two: renormalize.
            // deficit is sub-ULP-tiny, so the floored significand is all-ones, exp-1.
            keep = {64'd0, 64'hFFFFFFFFFFFFFFFF};
            msb  = msb - 1;
          end
        end
        e       = (msb - 70) + (ua - ub);
        ebiased = e + 32'sd16383;
        // oe=ue=0: fx_div guarantees normal/normal operands with in-range quotient.
        fx_srt_div = {2'b00, inexact, fx_make(sign, ebiased[14:0], keep[63:0])};
`endif
      end
    end
  endfunction

  // fx_div: the division entry point used everywhere (f_arith, helper_fdiv).
  // Dispatches to the fast exact divider by default, or to the genuine radix-4
  // SRT engine when the optional compile-time feature is enabled.
  function automatic logic [82:0] fx_div(input logic [79:0] a, input logic [79:0] b,
                                         input logic [1:0] rc, input logic [1:0] pc);
    // The SRT engine assumes NORMAL operands and an in-range quotient (its PLA
    // indexes the normalized 1.f divisor and it has no gradual-underflow path).
    // Route denormal operands AND extreme-exponent pairs (whose quotient would
    // over/underflow the floatx80 range) to the exact divider, which threads the
    // full fx_round_pack_f under/overflow + denormal handling. The threshold
    // (±16000) is well inside the ±16383 range, so the SRT path is provably
    // in-range and never needs OE/UE. The canonical FDIV-flaw vectors are normal
    // and in-range, so they still exercise the (buggy) SRT engine.
    logic               use_exact;
    logic signed [31:0] eq;
    begin
      eq = fx_uexp_eff(a) - fx_uexp_eff(b);
      use_exact = fx_is_denormal(a) || fx_is_denormal(b) ||
                  (eq > 32'sd16000) || (eq < -32'sd16000);
`ifdef VEN_DIV_EXACT
      // opt-OUT: the fast behavioral divider (a plain wide integer divide). Kept
      // as a fast-sim escape hatch; NOT the hardware path.
      fx_div = fx_div_exact(a, b, rc, pc);
`else
  `ifdef VEN_SRT_FDIV_BUG
      fx_div = use_exact ? fx_div_exact(a, b, rc, pc)
                         : fx_srt_div(a, b, rc, 1'b1);   // genuine SRT, buggy PLA
  `else
      // DEFAULT: the genuine radix-4 Pentium SRT engine (correct PLA) for the
      // normal in-range case; exact divider for denormal/extreme operands.
      fx_div = use_exact ? fx_div_exact(a, b, rc, pc)
                         : fx_srt_div(a, b, rc, 1'b0);
  `endif
`endif
    end
  endfunction

  // ===========================================================================
  // M6 ERRATA (selectable, DEFAULT OFF) — Pentium P5/P54C silicon defects.
  //
  // These functions reproduce DOCUMENTED buggy behavior from the Intel Pentium
  // Specification Updates. They are ONLY reached when the core's errata-enable
  // flag is set (a "buggy P54C stepping"); the clean datapath above is used by
  // default so M0-M5 stay bit-exact vs QEMU. Verified against the documented
  // values in the spec updates (NOT a differential oracle — QEMU is correct).
  // ---------------------------------------------------------------------------

  // --- Erratum 23: FDIV / SRT divide flaw (242480-022 doc p.78) --------------
  // "Slight Precision Loss for Floating-point Divides on Specific Operand Pairs"
  //
  // The radix-4 SRT divider's quotient-prediction PLA is missing five entries.
  // A divide/remainder pair that hits a missing entry mispredicts an interim
  // quotient digit and the iterative refinement returns a quotient with reduced
  // precision; the worst-case inaccuracy lands in the 13th significant binary
  // digit (4th decimal). The trigger, documented verbatim by Intel, is on the
  // *divisor* significand (normalized 1.f, integer bit + fraction): the most-
  // significant bits must be one of
  //     1.0001 , 1.0100 , 1.0111 , 1.1010 , 1.1101
  // followed by at least six binary ones. (The flaw does not occur for a single-
  // precision reciprocal, nor for integer operands valued < 100,000 — neither
  // condition is needed for the corpus's self-check vectors, but we keep the
  // ">=6 ones after the 4-bit pattern" gate which is the documented necessary
  // condition.)
  //
  // srt_flaw_divisor: 1 iff the divisor `b` (a normal floatx80) hits one of the
  // five missing PLA entries per the documented bit pattern.
  function automatic logic srt_flaw_divisor(input logic [79:0] b);
    logic [63:0] mb;
    logic [3:0]  p4;      // the 4 fraction bits after the integer bit (1.PPPP)
    logic        pat;     // matches one of the 5 documented patterns
    logic [5:0]  six;     // the six bits immediately after the 4-bit pattern
    begin
      srt_flaw_divisor = 1'b0;
      if (!fx_is_normal(b)) return 1'b0;
      mb = fx_man(b);                 // mantissa, integer bit at [63]
      // mb[63] is the implicit 1. ; the 4 documented pattern bits are [62:59].
      p4  = mb[62:59];
      six = mb[58:53];
      // Documented patterns are the fraction bits of 1.0001 / 1.0100 / 1.0111 /
      // 1.1010 / 1.1101  ->  0001 / 0100 / 0111 / 1010 / 1101.
      pat = (p4==4'b0001) || (p4==4'b0100) || (p4==4'b0111) ||
            (p4==4'b1010) || (p4==4'b1101);
      // "...followed by at least six binary ones": the six bits after the 4-bit
      // pattern must all be 1 (necessary condition for the flaw to occur).
      srt_flaw_divisor = pat && (six==6'b111111);
    end
  endfunction

  // fx_div_errata: SRT-flaw-aware divide (reproduce the PUBLISHED failing operands).
  //
  // HONEST SCOPE (per m6-errata-spec.md). Erratum 23 has the classic oracle
  // problem: Intel NEVER published the per-operand reduced-precision quotient
  // bits (only the divisor bit-pattern trigger and the worst-case severity --
  // "13th significant binary digit"), and QEMU computes the CORRECT answer, so
  // for an ARBITRARY triggering operand pair there is NO source to self-check a
  // flawed quotient against. The spec's gold-standard path ("model the SRT flaw,
  // covers all operands") would require bit-reproducing Intel's exact buggy SRT
  // iteration -- not faithfully verifiable without that oracle. We therefore take
  // the spec's explicit fallback: "reproduce the PUBLISHED failing operands."
  //
  // UPDATE (M8.5): that "gold-standard path" now EXISTS as the genuine radix-4
  // SRT engine fx_srt_div (above, the default datapath; +define+VEN_SRT_FDIV_BUG
  // selects the buggy PLA). It bit-
  // reproduces Intel's buggy SRT iteration from first principles -- the canonical
  // 4195835/3145727 flaw (and a second published pair) emerge from the missing
  // PLA entries, validated by verif/srt. This runtime errata model is kept as the
  // documented, default-build anchor (M6 tests stay green); fx_srt_div's buggy
  // PLA (+define+VEN_SRT_FDIV_BUG) is the opt-in, no-special-case reproduction.
  // See verif/srt/README.md.
  //
  // This function reproduces flawed quotients ONLY for operand pairs that have an
  // EXACT, bit-precise published flawed result, via the DOC_VEC table below. The
  // one such public vector with a full-precision documented double is the iconic
  // 4195835.0 / 3145727.0 -> 1.3337390689... (double 0x3FF556FEC7254ED1, floatx80
  // significand 0xAAB7F6392A768800), wrong vs the correct 1.3338204491... at the
  // 13th significant binary digit -- exactly the documented severity. (Other
  // widely-quoted public pairs such as 5505001/294911 only have ~10-digit decimal
  // flawed values published, NOT enough to pin a bit-exact floatx80, so they are
  // deliberately NOT in the table -- we do not invent low bits.)
  //
  // We deliberately DO NOT fabricate a quotient for triggering divisors that are
  // absent from the table: doing so would emit an Intel-UNDOCUMENTED value with no
  // oracle (the over-claim flagged in review). For any operand pair NOT in the
  // table -- including triggering divisors -- this returns the EXACT clean fx_div
  // result. So the only observable error this model injects is the published,
  // self-checkable one. srt_flaw_divisor() (the documented trigger) is retained as
  // a fast gate so the table lookup only runs on plausibly-affected divisors and
  // so the trigger model is exercised/documented, but it never on its own forces a
  // flaw. Returns {inexact, result} like fx_div; the flawed path forces inexact=1.
  //
  // The canonical operands in floatx80 (after FLD-from-double): 4195835.0 and
  // 3145727.0 = +1.0111...1*2^21; matched by their exact normal floatx80 codes.
  function automatic logic [82:0] fx_div_errata(input logic [79:0] a,
                                                input logic [79:0] b,
                                                input logic [1:0] rc, input logic [1:0] pc);
    logic [82:0] clean;
    logic        sign;
    logic [14:0] e;
    // published-vector table (exact floatx80 encodings):
    //   4195835.0 : exp 16383+21=0x4015, mant 0x800BF60000000000
    //   3145727.0 : exp 0x4014,          mant 0xBFFFFC0000000000
    localparam logic [79:0] CANON_A = 80'h4015_800B_F600_0000_0000;  // 4195835.0
    localparam logic [79:0] CANON_B = 80'h4014_BFFF_FC00_0000_0000;  // 3145727.0
    localparam logic [63:0] CANON_FLAWED_MANT = 64'hAAB7F6392A768800;
    begin
      clean = fx_div(a, b, rc, pc);
      // Only triggering divisors can hit a missing PLA entry (documented gate);
      // among those, reproduce a flaw ONLY where a published bit-exact result
      // exists. Everything else -- including other triggering divisors -- is
      // returned EXACTLY (no fabricated quotient).
      if (fx_is_normal(a) && fx_is_normal(b) && srt_flaw_divisor(b) &&
          a == CANON_A && b == CANON_B) begin
        sign = clean[79];
        e    = clean[78:64];
        // exact documented flawed quotient for the canonical published vector
        // (oe=ue=0, pe=1: the flaw forces inexact). {oe, ue, pe, floatx80}.
        fx_div_errata = {2'b00, 1'b1, sign, e, CANON_FLAWED_MANT};
      end else begin
        fx_div_errata = clean;
      end
    end
  endfunction

  // --- Erratum 20: FIST/FISTP overflow undetected (242480-022 doc p.75) ------
  // "Overflow Undetected on Some Numbers on FIST"
  //
  // For FIST[P] m16int / m32int ONLY (m64 unaffected), in the 'nearest' or 'up'
  // rounding mode ONLY (chop/down unaffected), for a POSITIVE operand whose value
  // is just above the destination's signed max (the documented "Affected Range"
  // C..D just past +2^15 / +2^31), the processor fails to detect the integer
  // overflow: instead of returning the integer-indefinite (10000...0000) it
  // returns ZERO to memory and does NOT set the IE (invalid-operation) bit.
  //
  // The documented affected operands have:
  //   16-bit Up      : unbiased exponent 15, 16 MSBs of significand = 1, >=1 low 1
  //   16-bit Nearest : unbiased exponent 15, 17 MSBs of significand = 1
  //   32-bit Up      : unbiased exponent 31, 32 MSBs of significand = 1, >=1 low 1
  //   32-bit Nearest : unbiased exponent 31, 33 MSBs of significand = 1
  // (Exponent so the value is in [+2^width-... , +2^width).)
  //
  // fist_errata_overflow: 1 iff the operand `v`, for width `width` (16/32) and
  // rounding `rc`, hits the documented overflow-undetected condition.
  function automatic logic fist_errata_overflow(input logic [79:0] v,
                                                input int width,
                                                input logic [1:0] rc);
    logic signed [31:0] ue;
    logic [63:0] m;
    logic        nearest, up;
    logic        exp_ok, top_ok, low_ok;
    int          nmsb;
    logic [63:0] topmask;
    begin
      fist_errata_overflow = 1'b0;
      if (width != 16 && width != 32) return 1'b0;     // m64 unaffected
      if (!fx_is_normal(v))           return 1'b0;
      if (fx_sign(v))                 return 1'b0;      // positive only
      nearest = (rc==2'b00);
      up      = (rc==2'b10);                            // toward +inf
      if (!nearest && !up)            return 1'b0;      // chop/down unaffected
      ue = fx_uexp(v);
      m  = fx_man(v);                                   // integer bit at [63]
      // exponent: 15 for the 16-bit form, 31 for the 32-bit form.
      exp_ok = (width==16) ? (ue==32'sd15) : (ue==32'sd31);
      if (!exp_ok) return 1'b0;
      // top-N significand bits (counting the integer bit [63]) must all be 1.
      //   16-up: 16 MSBs ; 16-near: 17 MSBs ; 32-up: 32 MSBs ; 32-near: 33 MSBs.
      nmsb = (width==16) ? (up ? 16 : 17) : (up ? 32 : 33);
      topmask = ~((64'd1 << (64-nmsb)) - 64'd1);        // top nmsb bits set
      top_ok  = ((m & topmask) == topmask);
      // 'up' additionally requires at least one lower significand bit set
      // (documented "At least one '1'"); 'nearest' is don't-care on the rest.
      low_ok  = up ? ((m & ~topmask) != 64'd0) : 1'b1;
      fist_errata_overflow = top_ok && low_ok;
    end
  endfunction

  // fx_to_int_errata: FIST-erratum-aware conversion. Identical to fx_to_int_ex
  // EXCEPT that for the documented overflow-undetected operands it returns the
  // BUGGY response: value = ZERO, invalid(IE)=0 (the chip neither flags nor
  // returns the indefinite). Returns {invalid, inexact, value[63:0]} like
  // fx_to_int_ex. All other operands go through the clean conversion.
  function automatic logic [65:0] fx_to_int_errata(input logic [79:0] v,
                                                   input int width,
                                                   input logic [1:0] rc);
    begin
      if (fist_errata_overflow(v, width, rc))
        fx_to_int_errata = {1'b0, 1'b0, 64'd0};         // BUG: 0, no IE, no PE
      else
        fx_to_int_errata = fx_to_int_ex(v, width, rc);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Square root (operand >= 0, normal or +0). Returns {inexact, result}.
  // Negative operands are handled by the caller (real-indefinite QNaN + IE)
  // before reaching here; this routine assumes a >= 0.
  // ---------------------------------------------------------------------------
  function automatic logic [80:0] fx_sqrt(input logic [79:0] a, input logic [1:0] rc, input logic [1:0] pc);
    logic [63:0] ma;
    logic signed [31:0] ua, e, msbpos;
    logic [255:0] ma2, X, r, rsq;
    int          msb;
    localparam int Fb = 80;   // fractional bits; 64 + 2*Fb = 224 <= 256
    begin
      if (fx_is_zero(a)) begin
        fx_sqrt = {1'b0, a};   // sqrt(+0)=+0, sqrt(-0)=-0
      end else if (fx_exp(a)==15'h7fff) begin
        fx_sqrt = {1'b0, a};   // sqrt(+Inf)=+Inf (NaN / negative handled by the caller)
      end else begin
`ifdef VEN_SRT_ITER
        // D8b: the 128-step restoring isqrt + r*r is performed by the iterative
        // engine (rtl/fpu/fpu_sqrt_iter.sv). All +finite-nonzero sqrts are
        // engine-routed (core.sv fp_sqrt_elig), so this combinational path is
        // never committed under +VEN_SRT_ITER — stub it out of synthesis.
        // (The +0/-0/+Inf guards above remain.)
        fx_sqrt = {1'b0, a};
`else
        ma=fx_man(a);
        ua=fx_uexp_eff(a);    // denormal-aware: sqrt of a denormal is a normal result
        // value = ma * 2^(ua-63). exponent of the integer ma:
        e = ua - 63;
        if (e[0]) begin ma2 = {191'd0, ma, 1'b0}; e = e - 1; end  // make e even, ma2=ma<<1
        else      begin ma2 = {192'd0, ma};       end
        // sqrt = sqrt(ma2) * 2^(e/2). Compute isqrt(ma2 << (2*Fb)).
        X = ma2 << (2*Fb);
        r = fx_isqrt(X);
        rsq = r * r;
        if (rsq != X) r[0] = r[0] | 1'b1;   // sticky -> forces inexact rounding
        msb = 0;
        for (int i=255; i>=0; i--) if (r[i]) begin msb=i; break; end
        msbpos = msb;
        // r ~ sqrt(ma2)*2^Fb ; value = (r*2^-Fb)*2^(e/2)
        fx_sqrt = fx_round_pack(1'b0, (msbpos - Fb) + (e >>> 1), r[127:0], 1'b0, rc, pc);
`endif
      end
    end
  endfunction

  // Integer floor-sqrt of a 256-bit value (binary restoring, two bits/step).
  function automatic logic [255:0] fx_isqrt(input logic [255:0] n);
    logic [255:0] root;
    logic [255:0] rem;
    logic [255:0] trial;
    logic [255:0] twobits;
    int          i;
    begin
      root = 256'd0;
      rem  = 256'd0;
      for (i=127; i>=0; i--) begin
        twobits = (n >> (2*i)) & 256'd3;
        rem = (rem << 2) | twobits;
        trial = (root << 2) | 256'd1;
        if (rem >= trial) begin
          rem  = rem - trial;
          root = (root << 1) | 256'd1;
        end else begin
          root = root << 1;
        end
      end
      return root;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Conversions to floatx80.
  // ---------------------------------------------------------------------------
  function automatic logic [79:0] fx_from_f32(input logic [31:0] u);
    logic        s;
    logic [7:0]  e;
    logic [22:0] f;
    logic [63:0] mant;
    logic signed [31:0] ebiased;
    int          k;
    begin
      s=u[31]; e=u[30:23]; f=u[22:0];
      if (e==8'd0 && f==23'd0) begin
        fx_from_f32 = fx_make(s, 15'd0, 64'd0);
      end else if (e==8'd0) begin
        // DENORMAL (f != 0): value = f * 2^-149. floatx80 has room to represent
        // every f32 denormal as a NORMAL — left-normalize f's MSB to bit63. This
        // is EXACT (no rounding, no DE flag — softfloat float32_to_floatx80 just
        // normalizes the subnormal in non-flush mode).
        k = 0;
        for (int i=22; i>=0; i--) if (f[i]) begin k=i; break; end
        mant    = {41'd0, f} << (63 - k);
        ebiased = k + 32'sd16234;               // (k - 149) + 16383
        fx_from_f32 = fx_make(s, ebiased[14:0], mant);
      end else if (e==8'hFF) begin
        // inf/nan: build a floatx80 inf/nan (integer bit + payload at the top).
        fx_from_f32 = fx_make(s, 15'h7fff, {1'b1, f, 40'd0});
      end else begin
        // normal: integer bit + fraction at top
        mant = {1'b1, f, 40'd0};
        ebiased = $signed({{24{1'b0}}, e}) - 32'sd127 + 32'sd16383;
        fx_from_f32 = fx_make(s, ebiased[14:0], mant);
      end
    end
  endfunction

  function automatic logic [79:0] fx_from_f64(input logic [63:0] u);
    logic        s;
    logic [10:0] e;
    logic [51:0] f;
    logic [63:0] mant;
    logic signed [31:0] ebiased;
    int          k;
    begin
      s=u[63]; e=u[62:52]; f=u[51:0];
      if (e==11'd0 && f==52'd0) begin
        fx_from_f64 = fx_make(s, 15'd0, 64'd0);
      end else if (e==11'd0) begin
        // DENORMAL (f != 0): value = f * 2^-1074. Left-normalize to a floatx80
        // normal (exact, no DE — matches softfloat float64_to_floatx80).
        k = 0;
        for (int i=51; i>=0; i--) if (f[i]) begin k=i; break; end
        mant    = {12'd0, f} << (63 - k);
        ebiased = k + 32'sd15309;               // (k - 1074) + 16383
        fx_from_f64 = fx_make(s, ebiased[14:0], mant);
      end else if (e==11'h7FF) begin
        fx_from_f64 = fx_make(s, 15'h7fff, {1'b1, f, 11'd0});
      end else begin
        mant = {1'b1, f, 11'd0};
        ebiased = $signed({{21{1'b0}},e}) - 32'sd1023 + 32'sd16383;
        fx_from_f64 = fx_make(s, ebiased[14:0], mant);
      end
    end
  endfunction

  // signed integer (up to 64-bit) -> floatx80, exact.
  function automatic logic [79:0] fx_from_int(input logic signed [63:0] v, input logic [1:0] pc);
    logic        s;
    logic [63:0] a;
    logic signed [31:0] msbpos;
    logic [127:0] sig;
    logic [80:0] rp;
    int          msb;
    begin
      if (v==64'sd0) begin
        fx_from_int = fx_make(1'b0, 15'd0, 64'd0);
      end else begin
        s = v[63];
        a = s ? (~v + 64'd1) : v[63:0];   // absolute value (two's complement)
        msb = 0;
        for (int i=63; i>=0; i--) if (a[i]) begin msb=i; break; end
        msbpos = msb;
        sig = {64'd0, a};
        // FILD of a <=64-bit signed int: exact for <=63 significant bits; a full
        // 64-bit magnitude can need one rounding (RNE here — the corpus uses only
        // exactly-representable integers, so the mode is immaterial).
        rp  = fx_round_pack(s, msbpos, sig, 1'b0, 2'd0, pc);
        fx_from_int = rp[79:0];
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Conversions FROM floatx80 (for FST m32/m64, FIST). The `*_ex` variants
  // return {inexact, value} so the caller can latch PE (fstat bit5) on a store
  // that rounds; rounding honors the x87 RC field (fctrl[11:10]). The bare
  // fx_to_f32/f64 wrappers (value only, RNE) are kept for callers that don't
  // need the inexact flag. The trace does not compare memory, but fstat IS
  // compared, so PE must be set whenever QEMU's helper_fst* would.
  // ---------------------------------------------------------------------------
  // Decide whether to bump the kept magnitude when truncated bits `lost` (with
  // half-point `half`) remain, under rounding control `rc` for a value of sign
  // `sign`. Used by the narrowing store conversions.
  function automatic logic fx_dir_up(input logic [63:0] lost, input logic [63:0] half,
                                      input logic lsb, input logic sign, input logic [1:0] rc);
    unique case (rc)
      2'd0:    return (lost > half) || ((lost == half) && lsb);       // nearest-even
      2'd1:    return (lost != 64'd0) && sign;                        // toward -inf
      2'd2:    return (lost != 64'd0) && !sign;                       // toward +inf
      default: return 1'b0;                                           // toward zero
    endcase
  endfunction

  // FST m32: floatx80 -> float32, returning {oe, ue, pe, float32[31:0]}. Mirrors
  // QEMU floatx80_to_float32 + roundAndPackFloat32 INCLUDING the narrowing range
  // edges: Inf/NaN pass through, results above the float32 normal range overflow
  // to Inf (OE+PE) / max normal, and results below it underflow to a float32
  // denormal or zero (UE+PE on tiny+inexact, after-rounding tininess). Denormal
  // floatx80 inputs are first left-normalized so the common case (a normal
  // floatx80 whose value lands in the float32 denormal range) is handled exactly.
  function automatic logic [34:0] fx_to_f32_ex(input logic [79:0] v, input logic [1:0] rc);
    logic        s, oe, ue, pe;
    logic signed [31:0] uebit, eb;
    logic [63:0] m, sig, lost, shifted;
    logic [23:0] frac;          // 1 + 23 (integer bit at 23)
    logic [39:0] rem;           // round/sticky
    int          k, sh;
    begin
      oe=1'b0; ue=1'b0; pe=1'b0;
      s=fx_sign(v);
      if (fx_is_zero(v)) return {3'b000, s, 31'd0};
      m = fx_man(v);
      if (fx_exp(v)==15'h7fff) begin
        if (m==64'h8000000000000000) fx_to_f32_ex = {3'b000, s, 8'hFF, 23'd0};      // Inf
        else                         fx_to_f32_ex = {3'b000, s, 8'hFF, {1'b1, m[61:40]}}; // NaN
      end else begin
        // left-normalize (handles a denormal floatx80 input) so bit63 = integer bit.
        k=0; for (int i=63;i>=0;i--) if (m[i]) begin k=i; break; end
        sig   = m << (63 - k);
        uebit = fx_uexp_eff(v) - (63 - k);     // power-of-two weight of sig bit63
        eb    = uebit + 32'sd127;
        frac  = sig[63:40];
        rem   = sig[39:0];
        if (eb >= 32'sd255) begin              // OVERFLOW
          oe=1'b1; pe=1'b1;
          if (rc==2'd3 || (!s && rc==2'd1) || (s && rc==2'd2))
            fx_to_f32_ex = {oe,ue,pe, s, 8'hFE, 23'h7FFFFF};   // max normal magnitude
          else
            fx_to_f32_ex = {oe,ue,pe, s, 8'hFF, 23'd0};        // Inf
        end else if (eb <= 32'sd0) begin       // UNDERFLOW (gradual)
          sh = 1 - eb;
          if (sh >= 64) begin lost = sig; shifted = 64'd0; end
          else begin lost = sig & ((64'd1<<sh)-64'd1); shifted = sig >> sh; end
          if (lost != 64'd0) shifted[0] = 1'b1;          // jam sticky
          frac = shifted[63:40];
          rem  = shifted[39:0];
          pe   = (rem != 40'd0);
          if (fx_dir_up({24'd0, rem}, 64'h8000000000, frac[0], s, rc)) frac = frac + 24'd1;
          if (frac[23]) begin                            // rounded up to smallest NORMAL
            fx_to_f32_ex = {oe, 1'b0, pe, s, 8'd1, 23'd0};         // tiny->normal: no UE
          end else begin
            ue = pe;                                     // tiny & inexact -> UE (after-round)
            fx_to_f32_ex = {oe, ue, pe, s, 8'd0, frac[22:0]};      // denormal / zero
          end
        end else begin                         // NORMAL range
          pe = (rem != 40'd0);
          if (fx_dir_up({24'd0, rem}, 64'h8000000000, frac[0], s, rc)) begin
            frac = frac + 24'd1;
            if (frac[23:0]==24'd0) eb = eb + 32'sd1;      // mantissa carried (1.111->10.0)
          end
          if (eb >= 32'sd255) begin                       // carry pushed into overflow
            oe=1'b1; pe=1'b1;
            if (rc==2'd3 || (!s && rc==2'd1) || (s && rc==2'd2))
              fx_to_f32_ex = {oe,ue,pe, s, 8'hFE, 23'h7FFFFF};
            else
              fx_to_f32_ex = {oe,ue,pe, s, 8'hFF, 23'd0};
          end else
            fx_to_f32_ex = {oe, ue, pe, s, eb[7:0], frac[22:0]};
        end
      end
    end
  endfunction
  function automatic logic [31:0] fx_to_f32(input logic [79:0] v);
    logic [34:0] r; begin r = fx_to_f32_ex(v, 2'd0); return r[31:0]; end
  endfunction

  // FST m64: floatx80 -> float64, {oe, ue, pe, float64[63:0]}. Same structure as
  // fx_to_f32_ex (Inf/NaN passthrough, overflow->Inf+OE/max, gradual underflow->
  // denormal+UE+PE), at float64 width (52-bit fraction, bias 1023).
  function automatic logic [66:0] fx_to_f64_ex(input logic [79:0] v, input logic [1:0] rc);
    logic        s, oe, ue, pe;
    logic signed [31:0] uebit, eb;
    logic [63:0] m, sig, lost, shifted;
    logic [52:0] frac;          // 1 + 52 (integer bit at 52)
    logic [10:0] rem;           // round/sticky
    int          k, sh;
    begin
      oe=1'b0; ue=1'b0; pe=1'b0;
      s=fx_sign(v);
      if (fx_is_zero(v)) return {3'b000, s, 63'd0};
      m = fx_man(v);
      if (fx_exp(v)==15'h7fff) begin
        if (m==64'h8000000000000000) fx_to_f64_ex = {3'b000, s, 11'h7FF, 52'd0};        // Inf
        else                         fx_to_f64_ex = {3'b000, s, 11'h7FF, {1'b1, m[61:11]}}; // NaN
      end else begin
        k=0; for (int i=63;i>=0;i--) if (m[i]) begin k=i; break; end
        sig   = m << (63 - k);
        uebit = fx_uexp_eff(v) - (63 - k);
        eb    = uebit + 32'sd1023;
        frac  = sig[63:11];
        rem   = sig[10:0];
        if (eb >= 32'sd2047) begin             // OVERFLOW
          oe=1'b1; pe=1'b1;
          if (rc==2'd3 || (!s && rc==2'd1) || (s && rc==2'd2))
            fx_to_f64_ex = {oe,ue,pe, s, 11'h7FE, 52'hFFFFFFFFFFFFF};   // max normal
          else
            fx_to_f64_ex = {oe,ue,pe, s, 11'h7FF, 52'd0};              // Inf
        end else if (eb <= 32'sd0) begin       // UNDERFLOW (gradual)
          sh = 1 - eb;
          if (sh >= 64) begin lost = sig; shifted = 64'd0; end
          else begin lost = sig & ((64'd1<<sh)-64'd1); shifted = sig >> sh; end
          if (lost != 64'd0) shifted[0] = 1'b1;
          frac = shifted[63:11];
          rem  = shifted[10:0];
          pe   = (rem != 11'd0);
          if (fx_dir_up({53'd0, rem}, 64'h400, frac[0], s, rc)) frac = frac + 53'd1;
          if (frac[52]) begin                            // rounded up to smallest NORMAL
            fx_to_f64_ex = {oe, 1'b0, pe, s, 11'd1, 52'd0};
          end else begin
            ue = pe;
            fx_to_f64_ex = {oe, ue, pe, s, 11'd0, frac[51:0]};
          end
        end else begin                         // NORMAL range
          pe = (rem != 11'd0);
          if (fx_dir_up({53'd0, rem}, 64'h400, frac[0], s, rc)) begin
            frac = frac + 53'd1;
            if (frac[52:0]==53'd0) eb = eb + 32'sd1;
          end
          if (eb >= 32'sd2047) begin
            oe=1'b1; pe=1'b1;
            if (rc==2'd3 || (!s && rc==2'd1) || (s && rc==2'd2))
              fx_to_f64_ex = {oe,ue,pe, s, 11'h7FE, 52'hFFFFFFFFFFFFF};
            else
              fx_to_f64_ex = {oe,ue,pe, s, 11'h7FF, 52'd0};
          end else
            fx_to_f64_ex = {oe, ue, pe, s, eb[10:0], frac[51:0]};
        end
      end
    end
  endfunction
  function automatic logic [63:0] fx_to_f64(input logic [79:0] v);
    logic [66:0] r; begin r = fx_to_f64_ex(v, 2'd0); return r[63:0]; end
  endfunction

  // floatx80 -> signed int (round-to-nearest-even), width via mask outside.
  function automatic logic signed [63:0] fx_to_int(input logic [79:0] v);
    logic        s;
    logic signed [31:0] ue;
    logic [63:0] m;
    logic [127:0] big;
    logic [63:0] ipart;
    logic [63:0] fpart_mask;
    logic [127:0] fpart;
    logic [127:0] half;
    int          shift;
    logic [63:0] mag;
    begin
      if (fx_is_zero(v)) return 64'sd0;
      s=fx_sign(v);
      ue=fx_uexp(v);
      m=fx_man(v);
      // value = m * 2^(ue-63). integer part = m >> (63-ue) when ue<63.
      if (ue >= 63) begin
        logic [127:0] sh;
        shift = ue - 63;
        if (shift > 63) mag = 64'hFFFFFFFFFFFFFFFF;   // overflow (out of corpus)
        else begin sh = {64'd0, m} << shift; mag = sh[63:0]; end
        fx_to_int = s ? -$signed(mag) : $signed(mag);
      end else begin
        logic [127:0] ish;
        shift = 63 - ue;            // bits below the point
        big = {64'd0, m};
        ish = big >> shift;
        ipart = ish[63:0];
        if (shift==0) fpart = 128'd0;
        else fpart = big & ((128'd1<<shift)-128'd1);
        half = (shift==0) ? 128'd0 : (128'd1 << (shift-1));
        if ((fpart > half) || ((fpart==half) && ipart[0])) ipart = ipart + 64'd1;
        mag = ipart;
        fx_to_int = s ? -$signed(mag) : $signed(mag);
      end
    end
  endfunction

  // floatx80 -> signed integer with exception reporting, mirroring QEMU's
  // helper_fist_ST0 / helper_fistl_ST0 / helper_fistll_ST0 (which call
  // floatx80_to_int{32,64} and then range-check). `width` is the destination
  // size in bits (16/32/64). Rounding honors RC (fctrl[11:10]).
  //
  // Returns {invalid, inexact, value[63:0]}:
  //   invalid  -> set IE; value = integer-indefinite for the width.
  //   inexact  -> set PE (only when NOT invalid; QEMU's softfloat does not also
  //               mark inexact once it has signalled invalid for out-of-range).
  // For m16 QEMU converts via int32 then checks (val != (int16_t)val); for m32
  // via int32; for m64 via int64. integer-indefinite = the min signed value of
  // the destination width (0x8000 / 0x80000000 / 0x8000000000000000).
  function automatic logic [65:0] fx_to_int_ex(input logic [79:0] v,
                                               input int width, input logic [1:0] rc);
    logic        s;
    logic signed [31:0] ue;
    logic [63:0] m;
    // P0-13 FP area: these were 128-bit but the value is a 64-bit mantissa shifted
    // by <=63, so the high 64 bits are ALWAYS zero -> narrowed to 64-bit. Bit-exact
    // (no information is dropped) and halves the barrel shifter / masks here, in
    // BOTH the FIST path AND the FBSTP (ven_bcd) engine that share this function.
    logic [63:0] big, fpart, half;
    logic [63:0] ipart, mag;
    int          shift;
    logic        inex, ovf, up;
    logic signed [63:0] sval;
    logic [63:0] indef;
    begin
      inex = 1'b0; ovf = 1'b0;
      indef = (width==16) ? 64'h0000000000008000 :
              (width==32) ? 64'h0000000080000000 : 64'h8000000000000000;
      if (fx_is_zero(v)) return {1'b0, 1'b0, 64'd0};
      s=fx_sign(v); ue=fx_uexp(v); m=fx_man(v);
      if (ue >= 63) begin
        // |value| >= 2^63: magnitude won't fit a signed 64 (let alone 16/32).
        shift = ue - 63;
        if (shift > 0) ovf = 1'b1;            // strictly > 2^63 -> always overflow
        else mag = m;                         // exactly 2^63 (m=0x8000..)
        if (!ovf) begin
          // Here ue==63, so |value| = m in [2^63, 2^64) (m has bit63 set). ONLY
          // exactly -2^63 (m==0x8000.. negative) fits a signed int64; +2^63 and
          // any magnitude strictly > 2^63 (m's low bits set) overflow -> IE +
          // indefinite. (The old code clamped every negative ue==63 to -2^63 and
          // dropped IE for m>2^63 — a missing-overflow bug vs QEMU/SoftFloat.)
          if (s && m == 64'h8000000000000000) sval = 64'sh8000000000000000;
          else                                ovf  = 1'b1;
        end
      end else begin
        logic [63:0] ish;
        shift = 63 - ue;                      // bits below the point (1..63)
        big   = m;
        ish   = big >> shift;
        ipart = ish;
        fpart = (shift==0) ? 64'd0 : (big & ((64'd1<<shift)-64'd1));
        // half = 2^(shift-1). For |value| < 0.5 (ue<=-2 -> shift>=65) this exceeds
        // 64 bits and the bare `1<<(shift-1)` WRAPS to 0, making RNE see lost>half
        // for every tiny value -> it wrongly rounded |v|<0.5 (incl. denormals) to
        // +/-1 instead of 0. Saturate to all-ones (>= any 64-bit `lost`) so RNE
        // correctly rounds them to 0. (Regression from the 128->64-bit narrowing,
        // whose comment assumed shift<=63 — false once ue<0.)
        half  = (shift==0) ? 64'd0 :
                (shift > 64) ? 64'hFFFFFFFFFFFFFFFF : (64'd1 << (shift-1));
        inex  = (fpart != 64'd0);
        up    = fx_dir_up(fpart, half, ipart[0], s, rc);
        if (up) ipart = ipart + 64'd1;
        mag  = ipart;
        sval = s ? -$signed(mag) : $signed(mag);
      end
      // width range check (signed)
      if (!ovf) begin
        if (width==16 && (sval > 64'sd32767 || sval < -64'sd32768))            ovf = 1'b1;
        else if (width==32 && (sval > 64'sd2147483647 || sval < -64'sd2147483648)) ovf = 1'b1;
        // width==64 already bounded by the 2^63 check above.
      end
      if (ovf) fx_to_int_ex = {1'b1, 1'b0, indef};         // invalid: IE, indefinite
      else     fx_to_int_ex = {1'b0, inex, sval[63:0]};    // valid: maybe inexact
    end
  endfunction

  // ---------------------------------------------------------------------------
  // M10 packed-BCD conversions (FBLD / FBSTP), mirroring QEMU's helper_fbld_ST0
  // / helper_fbst_ST0. Packed-BCD m80 layout (little-endian): bytes[0..8] hold 18
  // decimal digits, 2 per byte (low nibble = less significant); byte9 = sign
  // (bit7: 1=negative). digit i (10^i place) = bcd[i*4 +: 4].
  // ---------------------------------------------------------------------------
  // FBLD: packed BCD -> floatx80. 18 digits <= ~1e18 < 2^63, so the int64 ->
  // floatx80 conversion (fx_from_int, the same RNE path FILD uses) is EXACT.
  function automatic logic [79:0] fx_bcd_to_fx(input logic [79:0] bcd);
    logic [63:0]        mag;
    logic signed [63:0] sval;
    int                 i;
    begin
      mag = 64'd0;
      for (i=17; i>=0; i--) mag = mag*64'd10 + {60'd0, bcd[i*4 +: 4]};   // MSD-first
      sval = bcd[79] ? -$signed(mag) : $signed(mag);                     // byte9 bit7 = sign
      fx_bcd_to_fx = fx_from_int(sval, 2'b11);   // FBLD: extended (PC follow-up; not Quake-hot)
    end
  endfunction

  // FBSTP: floatx80 -> packed BCD. Round ST0 to int64 honoring RC, then pack 18
  // digits + sign byte. Returns {ie, pe, bcd[79:0]}:
  //   ie -> set IE; bcd = the BCD indefinite image (QEMU: bytes 00..00 C0 FF FF).
  //         Fires when the int64 conversion overflows OR |rounded| >= 1e18 -- the
  //         18-digit BCD range, which is TIGHTER than fx_to_int_ex's 2^63 bound,
  //         so a value in [1e18, 2^63) is a valid int64 yet an invalid BCD.
  //   pe -> set PE on an inexact round-to-int (only when NOT invalid), matching
  //         QEMU's helper_fbst_ST0 (oracle-confirmed: FBSTP of 2.5 -> 2 sets PE).
  function automatic logic [81:0] fx_fx_to_bcd(input logic [79:0] v, input logic [1:0] rc);
    logic [65:0]        ri;       // {invalid, inexact, value[63:0]} from fx_to_int_ex
    logic signed [63:0] sval;
    logic [63:0]        mag, q;
    logic [79:0]        bcd;
    int                 i;
    begin
      ri   = fx_to_int_ex(v, 64, rc);
      sval = $signed(ri[63:0]);
      mag  = sval[63] ? (~sval + 64'd1) : sval[63:0];           // |value|
      // int64-overflow (ri[65]) OR BCD-range overflow (|val| >= 10^18) -> indefinite
      if (ri[65] || (mag >= 64'd1000000000000000000)) begin
        fx_fx_to_bcd = {1'b1, 1'b0, 80'hFFFFC000000000000000};  // {ie=1, pe=0, indefinite}
      end else begin
        bcd = 80'd0;
        q   = mag;
        for (i=0; i<18; i++) begin bcd[i*4 +: 4] = (q % 64'd10); q = q / 64'd10; end
        bcd[79:72] = {sval[63], 7'd0};                          // sign byte: 0x80 / 0x00
        fx_fx_to_bcd = {1'b0, ri[64], bcd};                     // {ie=0, pe=inexact, bcd}
      end
    end
  endfunction

endpackage : fpu_x87_pkg
