// fpu/fpu_x87_pkg.sv — x87 floatx80 datapath helpers (M3).
//
// A self-contained, bit-exact-vs-QEMU floatx80 engine for the x87 FPU, covering
// the operands the M3 corpus exercises: NORMAL finite values and signed zero,
// round-to-nearest-even at 64-bit precision (the default control word 0x037f).
//
// Reference: QEMU softfloat floatx80 (fpu/softfloat.c) + the i386 fpu_helper.c
// semantics (compare ccval table, FXAM classify, FCHS/FABS, conversions). The
// algorithms here were validated bit-exact against QEMU goldens for every
// add/sub/mul/div/sqrt and float32/64<->floatx80, int<->floatx80 case in the
// tx_* corpus before being transcribed to RTL (see verif/qemu-trace goldens).
//
// floatx80 canonical layout (matches gen_trace.py / the trace hex strings):
//   bit79     = sign
//   bits78:64 = biased exponent (bias 16383)
//   bits63:0  = mantissa (explicit integer bit at 63 for normals)
// A packed 80-bit logic vector [79:0] carries this directly.
//
// Out-of-corpus inputs (inf / NaN / denormal results, non-default RC/PC) are NOT
// guaranteed bit-exact here — the core HALTs on those decode paths (Tier-3
// deferral, m3-fpu-spec.md) rather than emitting a wrong answer. This package
// implements the normal-operand datapath only.

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
  function automatic logic [80:0] fx_round_pack(  // {inexact, floatx80[79:0]}
      input logic         sign,
      input logic signed [31:0] unbiased,
      input logic [127:0] sig,
      input logic         pre_inexact,  // sticky from earlier truncation (div/sqrt)
      input logic [1:0]   rc);          // rounding control (fctrl[11:10])
    int          msb;
    int          extra;
    logic [127:0] keep_v;
    logic [127:0] rem_v;
    logic [127:0] half_v;
    logic [63:0] mant;
    logic        inexact;
    logic        round_up;
    logic signed [31:0] ub;
    logic [127:0] shifted;
    logic signed [31:0] ebiased;
    begin
      inexact = pre_inexact;
      ub = unbiased;
      if (sig==128'd0) begin
        fx_round_pack = {1'b0, fx_make(sign, 15'd0, 64'd0)};
      end else begin
        // find MSB index
        msb = 0;
        for (int i=127; i>=0; i--) begin
          if (sig[i]) begin msb = i; break; end
        end
        extra = msb - 63;
        if (extra > 0) begin
          keep_v = sig >> extra;
          rem_v  = sig & ((128'd1 << extra) - 128'd1);
          half_v = 128'd1 << (extra-1);
          if (rem_v != 128'd0) inexact = 1'b1;
          // Decide whether to increment the kept mantissa per RC. The directed
          // modes look at the SIGN of the value and whether anything was lost.
          unique case (rc)
            2'd0:    // round to nearest even
              round_up = (rem_v > half_v) || ((rem_v == half_v) && keep_v[0]);
            2'd1:    // toward -inf: bump magnitude up only for negative results
              round_up = (rem_v != 128'd0) && sign;
            2'd2:    // toward +inf: bump magnitude up only for positive results
              round_up = (rem_v != 128'd0) && !sign;
            default: // toward zero (truncate): never bump
              round_up = 1'b0;
          endcase
          if (round_up) begin
            keep_v = keep_v + 128'd1;
            if (keep_v[64]) begin           // mantissa overflowed 64 bits
              keep_v = keep_v >> 1;
              ub = ub + 1;
            end
          end
          mant = keep_v[63:0];
        end else begin
          shifted = sig << (-extra);
          mant = shifted[63:0];
        end
        ebiased = ub + 32'sd16383;
        fx_round_pack = {inexact, fx_make(sign, ebiased[14:0], mant)};
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Add / subtract on normal+zero operands. Returns {inexact, result}.
  // For subtract the caller flips b's sign. Handles signed-zero result sign per
  // RNE (x - x = +0; -0 + -0 = -0).
  // ---------------------------------------------------------------------------
  function automatic logic [80:0] fx_add(input logic [79:0] a, input logic [79:0] b,
                                         input logic [1:0] rc);
    logic        sa, sb, sign;
    logic [14:0] ea, eb;
    logic [63:0] ma, mb;
    logic signed [31:0] ua, ub, topexp, msbpos;
    logic [127:0] A, B, s;
    int          shift;
    int          msb;
    begin
      sa=fx_sign(a); sb=fx_sign(b); ea=fx_exp(a); eb=fx_exp(b); ma=fx_man(a); mb=fx_man(b);
      if (fx_is_zero(a) && fx_is_zero(b)) begin
        // (+0)+(+0)=+0, (-0)+(-0)=-0; mixed-sign 0+0 = +0 except round-down=-0.
        if (sa == sb) fx_add = {1'b0, fx_make(sa, 15'd0, 64'd0)};
        else          fx_add = {1'b0, fx_make(rc==2'd1, 15'd0, 64'd0)};
      end else if (fx_is_zero(a)) begin
        fx_add = {1'b0, b};
      end else if (fx_is_zero(b)) begin
        fx_add = {1'b0, a};
      end else begin
        ua = fx_uexp(a);
        ub = fx_uexp(b);
        // place each mantissa with 63 guard bits below bit63 -> MSB at bit126
        A = {1'b0, ma, 63'd0};
        B = {1'b0, mb, 63'd0};
        if (ua >= ub) begin
          shift = ua - ub;
          if (shift > 127) B = 128'd0; else B = B >> shift;
          topexp = ua;
        end else begin
          shift = ub - ua;
          if (shift > 127) A = 128'd0; else A = A >> shift;
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
          fx_add = {1'b0, fx_make(rc==2'd1, 15'd0, 64'd0)};
        end else begin
          msb = 0;
          for (int i=127; i>=0; i--) if (s[i]) begin msb=i; break; end
          msbpos = msb;
          // A/B had MSB at bit126 == weight 2^topexp; so weight of bit i = topexp+(i-126)
          fx_add = fx_round_pack(sign, topexp + (msbpos - 126), s, 1'b0, rc);
        end
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Multiply. Returns {inexact, result}.
  // ---------------------------------------------------------------------------
  function automatic logic [80:0] fx_mul(input logic [79:0] a, input logic [79:0] b,
                                         input logic [1:0] rc);
    logic        sa, sb, sign;
    logic [63:0] ma, mb;
    logic signed [31:0] ua, ub, msbpos;
    logic [127:0] prod;
    int          msb;
    begin
      sa=fx_sign(a); sb=fx_sign(b); sign=sa^sb;
      if (fx_is_zero(a) || fx_is_zero(b)) begin
        fx_mul = {1'b0, fx_make(sign, 15'd0, 64'd0)};
      end else begin
        ma=fx_man(a); mb=fx_man(b);
        ua=fx_uexp(a); ub=fx_uexp(b);
        prod = {64'd0, ma} * {64'd0, mb};
        msb = 0;
        for (int i=127; i>=0; i--) if (prod[i]) begin msb=i; break; end
        msbpos = msb;
        // ma MSB at bit63 weight 2^ua ; product bit i weight = (ua-63)+(ub-63)+i
        fx_mul = fx_round_pack(sign, (ua-63) + (ub-63) + msbpos, prod, 1'b0, rc);
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Divide a/b. Returns {inexact, result}. Normal operands, b != 0.
  // ---------------------------------------------------------------------------
  function automatic logic [80:0] fx_div(input logic [79:0] a, input logic [79:0] b,
                                         input logic [1:0] rc);
    logic        sa, sb, sign;
    logic [63:0] ma, mb;
    logic signed [31:0] ua, ub, msbpos;
    logic [191:0] num, q, rem;
    logic [127:0] qlo;
    int          msb;
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
        fx_div = {1'b0, fx_make(sign, 15'h7fff, 64'h8000000000000000)};
      end else if (fx_is_zero(a)) begin
        fx_div = {1'b0, fx_make(sign, 15'd0, 64'd0)};
      end else begin
        ma=fx_man(a); mb=fx_man(b);
        ua=fx_uexp(a); ub=fx_uexp(b);
        num = {128'd0, ma} << P;            // ma << P
        q   = num / {128'd0, mb};
        rem = num - q * {128'd0, mb};
        if (rem != 192'd0) q[0] = q[0] | 1'b1;   // exact-division sticky bit
        msb = 0;
        for (int i=135; i>=0; i--) if (q[i]) begin msb=i; break; end
        msbpos = msb;
        qlo = q[127:0];
        // value(ma/mb) ~ q * 2^-P ; weight of q's MSB = msbpos - P.
        // total value = (ma/mb)*2^(ua-ub) -> unbiased of MSB:
        fx_div = fx_round_pack(sign, (msbpos - P) + (ua - ub), qlo, 1'b0, rc);
      end
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
  function automatic logic [80:0] fx_div_errata(input logic [79:0] a,
                                                input logic [79:0] b,
                                                input logic [1:0] rc);
    logic [80:0] clean;
    logic        sign;
    logic [14:0] e;
    // published-vector table (exact floatx80 encodings):
    //   4195835.0 : exp 16383+21=0x4015, mant 0x800BF60000000000
    //   3145727.0 : exp 0x4014,          mant 0xBFFFFC0000000000
    localparam logic [79:0] CANON_A = 80'h4015_800B_F600_0000_0000;  // 4195835.0
    localparam logic [79:0] CANON_B = 80'h4014_BFFF_FC00_0000_0000;  // 3145727.0
    localparam logic [63:0] CANON_FLAWED_MANT = 64'hAAB7F6392A768800;
    begin
      clean = fx_div(a, b, rc);
      // Only triggering divisors can hit a missing PLA entry (documented gate);
      // among those, reproduce a flaw ONLY where a published bit-exact result
      // exists. Everything else -- including other triggering divisors -- is
      // returned EXACTLY (no fabricated quotient).
      if (fx_is_normal(a) && fx_is_normal(b) && srt_flaw_divisor(b) &&
          a == CANON_A && b == CANON_B) begin
        sign = clean[79];
        e    = clean[78:64];
        // exact documented flawed quotient for the canonical published vector.
        fx_div_errata = {1'b1, sign, e, CANON_FLAWED_MANT};
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
  function automatic logic [80:0] fx_sqrt(input logic [79:0] a, input logic [1:0] rc);
    logic [63:0] ma;
    logic signed [31:0] ua, e, msbpos;
    logic [255:0] ma2, X, r, rsq;
    int          msb;
    localparam int Fb = 80;   // fractional bits; 64 + 2*Fb = 224 <= 256
    begin
      if (fx_is_zero(a)) begin
        fx_sqrt = {1'b0, a};   // sqrt(+0)=+0, sqrt(-0)=-0
      end else begin
        ma=fx_man(a);
        ua=fx_uexp(a);
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
        fx_sqrt = fx_round_pack(1'b0, (msbpos - Fb) + (e >>> 1), r[127:0], 1'b0, rc);
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
    begin
      s=u[31]; e=u[30:23]; f=u[22:0];
      if (e==8'd0 && f==23'd0) begin
        fx_from_f32 = fx_make(s, 15'd0, 64'd0);
      end else if (e==8'hFF) begin
        // inf/nan: build a floatx80 inf/nan (Tier-3; corpus avoids, but be sane)
        fx_from_f32 = fx_make(s, 15'h7fff, {1'b1, f, 40'd0});
      end else begin
        // normal (corpus uses only normals); integer bit + fraction at top
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
    begin
      s=u[63]; e=u[62:52]; f=u[51:0];
      if (e==11'd0 && f==52'd0) begin
        fx_from_f64 = fx_make(s, 15'd0, 64'd0);
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
  function automatic logic [79:0] fx_from_int(input logic signed [63:0] v);
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
        rp  = fx_round_pack(s, msbpos, sig, 1'b0, 2'd0);
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

  function automatic logic [32:0] fx_to_f32_ex(input logic [79:0] v, input logic [1:0] rc);
    logic        s;
    logic signed [31:0] ue;
    logic [63:0] m;
    logic [23:0] frac;          // 1 + 23
    logic [39:0] rem;
    logic        inex;
    logic signed [31:0] eb;
    begin
      s=fx_sign(v);
      if (fx_is_zero(v)) return {1'b0, s, 31'd0};
      ue = fx_uexp(v);
      m  = fx_man(v);
      // top 24 bits = m[63:40]; rem = m[39:0]; half = 0x80_0000_0000
      frac = m[63:40];
      rem  = m[39:0];
      inex = (rem != 40'd0);
      if (fx_dir_up({24'd0, rem}, 64'h8000000000, frac[0], s, rc)) begin
        frac = frac + 24'd1;
        if (frac[23:0]==24'd0) ue = ue + 1;   // mantissa carried (1.111->10.0)
      end
      eb = ue + 127;
      fx_to_f32_ex = {inex, s, eb[7:0], frac[22:0]};
    end
  endfunction
  function automatic logic [31:0] fx_to_f32(input logic [79:0] v);
    logic [32:0] r; begin r = fx_to_f32_ex(v, 2'd0); return r[31:0]; end
  endfunction

  function automatic logic [64:0] fx_to_f64_ex(input logic [79:0] v, input logic [1:0] rc);
    logic        s;
    logic signed [31:0] ue;
    logic [63:0] m;
    logic [52:0] frac;
    logic [10:0] rem;
    logic        inex;
    logic signed [31:0] eb;
    begin
      s=fx_sign(v);
      if (fx_is_zero(v)) return {1'b0, s, 63'd0};
      ue = fx_uexp(v);
      m  = fx_man(v);
      frac = m[63:11];
      rem  = m[10:0];
      inex = (rem != 11'd0);
      if (fx_dir_up({53'd0, rem}, 64'h400, frac[0], s, rc)) begin
        frac = frac + 53'd1;
        if (frac[52:0]==53'd0) ue = ue + 1;
      end
      eb = ue + 1023;
      fx_to_f64_ex = {inex, s, eb[10:0], frac[51:0]};
    end
  endfunction
  function automatic logic [63:0] fx_to_f64(input logic [79:0] v);
    logic [64:0] r; begin r = fx_to_f64_ex(v, 2'd0); return r[63:0]; end
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
    logic [127:0] big, fpart, half;
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
          // value == +/-2^63 exactly: fits int64 only as the negative min.
          if (s) sval = 64'sh8000000000000000;
          else   ovf = 1'b1;                  // +2^63 doesn't fit signed 64
        end
      end else begin
        logic [127:0] ish;
        shift = 63 - ue;                      // bits below the point
        big   = {64'd0, m};
        ish   = big >> shift;
        ipart = ish[63:0];
        fpart = (shift==0) ? 128'd0 : (big & ((128'd1<<shift)-128'd1));
        half  = (shift==0) ? 128'd0 : (128'd1 << (shift-1));
        inex  = (fpart != 128'd0);
        up    = fx_dir_up(fpart[63:0], half[63:0], ipart[0], s, rc);
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

endpackage : fpu_x87_pkg
