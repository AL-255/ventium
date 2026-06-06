// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/ventium_x87_pkg.sv — x87 INSTRUCTION-LEVEL helpers (R2 modularization,
// docs/rtl-refactor-plan.md). These are the PURE combinational helpers that wrap
// the floatx80 datapath ops of fpu_x87_pkg (fx_add/fx_mul/fx_div/...) into the
// x87-instruction semantics the core's S_FEXEC arm needs: compare codes, NaN
// classifiers, the #IA/#ZE/#PE decision, FXAM/FCONST tables, memory-operand
// coercion, and the masked-default arithmetic evaluator.
//
// Extracted VERBATIM from core.sv (the bodies use ONLY their args + the
// fpu_x87_pkg fx_* functions — no module state), so this is a no-op to the
// netlist (a pure-function package move). fri()/fst()/fp_bop() were NOT moved:
// they read module state (ftop / fp_st[] / gpr[]) and stay in core.sv.
//
// Imports fpu_x87_pkg::* (every body calls fx_exp/fx_man/fx_is_zero/fx_sign/
// fx_add/fx_mul/fx_div/fx_div_errata/fx_from_f32/fx_from_f64/fx_from_int).

package ventium_x87_pkg;

  import fpu_x87_pkg::*;

  // Compare two floatx80, return {C3,C2,C0} per QEMU fcom_ccval. The C1 bit is
  // left to the caller (compares clear only C3/C2/C0). less->001, equal->100,
  // greater->000, unordered->111 (unordered also when either is NaN).
  function automatic logic [2:0] fcom_codes(input logic [79:0] a, input logic [79:0] b);
    logic an, bn;   // NaN? (exp all-ones, mantissa != the pure-infinity pattern)
    begin
      an = (fx_exp(a)==15'h7fff) && (fx_man(a)!=64'h8000000000000000);
      bn = (fx_exp(b)==15'h7fff) && (fx_man(b)!=64'h8000000000000000);
      if (an || bn) fcom_codes = 3'b111;           // unordered: C3=1,C2=1,C0=1
      else if (fx_is_zero(a) && fx_is_zero(b)) fcom_codes = 3'b100;  // +0==-0 equal
      else if (fst_lt(a,b)) fcom_codes = 3'b001;   // less:  C0=1
      else if (fst_eq(a,b)) fcom_codes = 3'b100;   // equal: C3=1
      else                  fcom_codes = 3'b000;   // greater
    end
  endfunction
  // Ordered numeric < and == on normal/zero floatx80 (no NaN here).
  function automatic logic fst_eq(input logic [79:0] a, input logic [79:0] b);
    if (fx_is_zero(a) && fx_is_zero(b)) return 1'b1;
    return (a==b);
  endfunction
  function automatic logic fst_lt(input logic [79:0] a, input logic [79:0] b);
    logic sa, sb;
    logic [78:0] mag_a, mag_b;
    begin
      if (fx_is_zero(a) && fx_is_zero(b)) return 1'b0;
      sa=fx_sign(a); sb=fx_sign(b);
      mag_a = a[78:0]; mag_b = b[78:0];   // exp:mant magnitude
      if (fx_is_zero(a)) sa = sb ? 1'b0 : 1'b0;  // 0 vs nonzero handled by mag below
      if (sa != sb) return sa & ~(fx_is_zero(a)&&fx_is_zero(b));  // a<b if a negative
      // same sign: compare magnitudes
      if (!sa) return (mag_a < mag_b);   // both positive
      else     return (mag_a > mag_b);   // both negative: larger magnitude is smaller
    end
  endfunction

  // NaN classifiers on floatx80 (x86 convention, snan_bit_is_one=false). A NaN
  // has exp==0x7fff and is not the pure-infinity pattern (mantissa 0x8000..).
  // QNaN = the quiet bit (mantissa bit 62) is set; SNaN = quiet bit clear with
  // some other mantissa bit set. Mirrors softfloat floatx80_is_{quiet,signaling}.
  function automatic logic fx_is_nan(input logic [79:0] v);
    return (fx_exp(v)==15'h7fff) && (fx_man(v)!=64'h8000000000000000);
  endfunction
  function automatic logic fx_is_snan(input logic [79:0] v);
    // exp all-ones, quiet bit (62) clear, and (low<<1) with bit62 masked != 0.
    return (fx_exp(v)==15'h7fff) && !fx_man(v)[62] &&
           (({fx_man(v)[63], 1'b0, fx_man(v)[61:0]} << 1) != 64'd0);
  endfunction
  // Infinity: exp all-ones with the pure-infinity mantissa (integer bit only).
  function automatic logic fx_is_inf(input logic [79:0] v);
    return (fx_exp(v)==15'h7fff) && (fx_man(v)==64'h8000000000000000);
  endfunction
  // Quiet an SNaN -> QNaN by setting the mantissa quiet bit (62); payload kept
  // (oracle: SNaN 0x7fffa000.. -> QNaN 0x7fffe000..).
  function automatic logic [79:0] fx_quietize(input logic [79:0] v);
    return {v[79:63], 1'b1, v[61:0]};
  endfunction

  // M11: the architectural 2-bit tag for ONE physical x87 register, derived from
  // its 1-bit internal empty flag + contents (FNSTENV/FNSAVE FTW word, FLDENV/
  // FRSTOR re-derivation). 11=empty, 01=zero, 10=special (Inf/NaN/denormal/
  // unnormal), 00=valid. Oracle-pinned (FTW=0x43FF for zero/valid/empty mix).
  function automatic logic [1:0] ftw_field(input logic empty, input logic [79:0] v);
    if (empty)                                          return 2'b11; // EMPTY
    else if (fx_exp(v)==15'd0 && fx_man(v)==64'd0)      return 2'b01; // ZERO
    else if (fx_exp(v)==15'h7fff || fx_exp(v)==15'd0 || !v[63])
                                                        return 2'b10; // SPECIAL
    else                                                return 2'b00; // VALID
  endfunction

  // M12: masked-default special-operand result for FADD/FSUB/FMUL/FDIV when an
  // operand is Inf or NaN. Returns {hit, ie, result[79:0]} -- hit=1 means the
  // datapath (fx_*) MUST be bypassed (it would do mantissa math on Inf/NaN and
  // return garbage). Mirrors QEMU softfloat under masked default control (CW=037F,
  // PC=11), oracle-pinned in verif/tests/tx_fp_special:
  //   any SNaN -> that NaN quieted, IE        (SNaN+1 -> QNaN, IE)
  //   any QNaN -> that NaN propagated, no IE  (QNaN+1 -> QNaN, no IE)
  //   Inf(+/-)Inf same/opp sign per op -> signed Inf / real-indefinite+IE
  //   Inf*0 -> indefinite+IE ; Inf*finite -> signed Inf
  //   Inf/Inf -> indefinite+IE ; Inf/finite -> signed Inf ; finite/Inf -> signed 0
  // (a,b) are in f_arith canonical order: add a+b, sub a-b, subr b-a, div a/b,
  // divr b/a. sub indices: 0 add, 1 mul, 4 sub, 5 subr, 6 div, 7 divr.
  function automatic logic [81:0] f_special(input logic [2:0] sub,
                                            input logic [79:0] a, input logic [79:0] b);
    logic sa, sb, pick_a, ie_nan;
    logic [63:0] ma, mb;
    begin
      sa = fx_sign(a); sb = fx_sign(b);
      ma = fx_man(a);  mb = fx_man(b);
      f_special = 82'd0;                                   // hit=0 -> use the datapath
      if (fx_is_nan(a) || fx_is_nan(b)) begin
        // NaN result selection per QEMU x87 pickNaN (oracle-pinned, tx_fp_special):
        // the operand with the LARGER 64-bit significand wins (the quiet bit makes a
        // QNaN outrank an SNaN of similar payload); ties -> positive sign; ties with
        // equal sign -> b. IE iff either is SNaN; the winner is quieted iff SNaN.
        if      (fx_is_nan(a) && !fx_is_nan(b)) pick_a = 1'b1;
        else if (!fx_is_nan(a) && fx_is_nan(b)) pick_a = 1'b0;
        else if (ma > mb)                       pick_a = 1'b1;
        else if (ma < mb)                       pick_a = 1'b0;
        else                                    pick_a = (sa==1'b0 && sb==1'b1);
        ie_nan = fx_is_snan(a) || fx_is_snan(b);
        if (pick_a) f_special = {1'b1, ie_nan, (fx_is_snan(a) ? fx_quietize(a) : a)};
        else        f_special = {1'b1, ie_nan, (fx_is_snan(b) ? fx_quietize(b) : b)};
      end
      else unique case (sub)
        3'd0: if (fx_is_inf(a) && fx_is_inf(b))
                   f_special = (sa==sb) ? {1'b1,1'b0,a} : {1'b1,1'b1,80'hFFFFC000000000000000};
              else if (fx_is_inf(a)) f_special = {1'b1,1'b0,a};
              else if (fx_is_inf(b)) f_special = {1'b1,1'b0,b};
        3'd4: if (fx_is_inf(a) && fx_is_inf(b))                                   // a - b
                   f_special = (sa!=sb) ? {1'b1,1'b0,a} : {1'b1,1'b1,80'hFFFFC000000000000000};
              else if (fx_is_inf(a)) f_special = {1'b1,1'b0,a};
              else if (fx_is_inf(b)) f_special = {1'b1,1'b0,{~b[79],b[78:0]}};
        3'd5: if (fx_is_inf(a) && fx_is_inf(b))                                   // b - a
                   f_special = (sa!=sb) ? {1'b1,1'b0,b} : {1'b1,1'b1,80'hFFFFC000000000000000};
              else if (fx_is_inf(b)) f_special = {1'b1,1'b0,b};
              else if (fx_is_inf(a)) f_special = {1'b1,1'b0,{~a[79],a[78:0]}};
        3'd1: if ((fx_is_inf(a) && fx_is_zero(b)) || (fx_is_inf(b) && fx_is_zero(a)))
                   f_special = {1'b1,1'b1,80'hFFFFC000000000000000};             // Inf*0
              else if (fx_is_inf(a) || fx_is_inf(b))
                   f_special = {1'b1,1'b0, {sa^sb, 15'h7fff, 64'h8000000000000000}};
        3'd6: if (fx_is_inf(a) && fx_is_inf(b)) f_special = {1'b1,1'b1,80'hFFFFC000000000000000};
              else if (fx_is_inf(a)) f_special = {1'b1,1'b0, {sa^sb, 15'h7fff, 64'h8000000000000000}};
              else if (fx_is_inf(b)) f_special = {1'b1,1'b0, {sa^sb, 15'd0, 64'd0}};
        default: if (fx_is_inf(a) && fx_is_inf(b)) f_special = {1'b1,1'b1,80'hFFFFC000000000000000};
              else if (fx_is_inf(b)) f_special = {1'b1,1'b0, {sa^sb, 15'h7fff, 64'h8000000000000000}};
              else if (fx_is_inf(a)) f_special = {1'b1,1'b0, {sa^sb, 15'd0, 64'd0}};
      endcase
    end
  endfunction

  // Compare-time invalid (#IA) per QEMU: FCOM/FTST/FICOM use floatx80_compare
  // (SIGNALING) -> IE on ANY NaN operand; FUCOM uses floatx80_compare_quiet ->
  // IE only on a SIGNALING NaN. `signaling` selects which rule applies.
  function automatic logic fcom_ie(input logic [79:0] a, input logic [79:0] b,
                                    input logic signaling);
    if (signaling) return fx_is_nan(a) || fx_is_nan(b);
    else           return fx_is_snan(a) || fx_is_snan(b);
  endfunction

  // Apply compare condition codes to fstat: clear C3/C2/C0 (mask 0x4500, NOT C1)
  // and set per {C3,C2,C0} (QEMU helper_fcom: fpus = (fpus & ~0x4500) | ccval).
  // `ie` latches the invalid-operation flag (fstat bit0), sticky, when the
  // compare is unordered against a NaN that the op signals on.
  function automatic logic [15:0] apply_cmp(input logic [15:0] cur,
                                            input logic [2:0] codes, input logic ie);
    logic [15:0] r;
    begin
      r = cur & ~16'h4500;
      if (codes[2]) r[14] = 1'b1;   // C3
      if (codes[1]) r[10] = 1'b1;   // C2
      if (codes[0]) r[8]  = 1'b1;   // C0
      if (ie)       r[0]  = 1'b1;   // IE (sticky)
      return r;
    end
  endfunction

  // The ROM constants QEMU emits (default rounding). 80-bit canonical.
  function automatic logic [79:0] fconst(input logic [2:0] sel);
    unique case (sel)
      3'd0: fconst = 80'h3fff8000000000000000;          // 1.0
      3'd1: fconst = 80'h4000d49a784bcd1b8afe;          // log2(10)
      3'd2: fconst = 80'h3fffb8aa3b295c17f0bc;          // log2(e)
      3'd3: fconst = 80'h4000c90fdaa22168c235;          // pi
      3'd4: fconst = 80'h3ffd9a209a84fbcff799;          // log10(2)
      3'd5: fconst = 80'h3ffeb17217f7d1cf79ac;          // ln(2)
      default: fconst = 80'h00000000000000000000;       // 0.0
    endcase
  endfunction

  // FXAM condition codes {C3,C2,C1,C0} per QEMU helper_fxam_ST0 (C1=sign always).
  function automatic logic [3:0] fxam_codes(input logic [79:0] v, input logic empty);
    logic c1;
    logic [14:0] e;
    logic [63:0] m;
    begin
      c1 = v[79];                    // C1 = sign bit (set even when empty)
      if (empty) return {1'b1, 1'b0, c1, 1'b1};   // Empty: C3=1,C2=0,C0=1
      e = fx_exp(v); m = fx_man(v);
      if (e==15'h7fff) begin
        // QEMU helper_fxam_ST0: Inf -> 0x500 (C2+C0), NaN -> 0x100 (C0). The C1
        // sign bit (0x200) is overlaid by the caller for both.
        if (m==64'h8000000000000000) return {1'b0,1'b1,c1,1'b1};  // Inf: C2=1,C0=1 (0x500)
        else                          return {1'b0,1'b0,c1,1'b1};  // NaN: C0=1   (0x100)
      end else if (e==15'd0) begin
        if (m==64'd0) return {1'b1,1'b0,c1,1'b0};   // Zero: C3=1
        else          return {1'b1,1'b1,c1,1'b0};   // Denormal: C3=1,C2=1
      end else begin
        return {1'b0,1'b1,c1,1'b0};                 // Normal: C2=1
      end
    end
  endfunction

  // The assembled memory operand value -> floatx80, by size/kind.
  function automatic logic [79:0] f_mem_as_float(input logic [79:0] m80, input logic [3:0] bytes);
    unique case (bytes)
      4'd4:  f_mem_as_float = fx_from_f32(m80[31:0]);
      4'd8:  f_mem_as_float = fx_from_f64(m80[63:0]);
      default: f_mem_as_float = m80;     // m80 already floatx80
    endcase
  endfunction
  function automatic logic [79:0] f_mem_as_int(input logic [79:0] m80, input logic [3:0] bytes);
    unique case (bytes)
      4'd2:  f_mem_as_int = fx_from_int({{48{m80[15]}}, m80[15:0]});
      4'd4:  f_mem_as_int = fx_from_int({{32{m80[31]}}, m80[31:0]});
      default: f_mem_as_int = fx_from_int($signed(m80[63:0]));
    endcase
  endfunction

  // ARITHMETIC: compute {inexact, result} for ST(dst) given two floatx80 ops and
  // the x87 group sub-op (0 add,1 mul,4 sub,5 subr,6 div,7 divr). For the memory/
  // ST0-dest forms, a=ST0, b=mem/ST(i). For STI-dest forms, a=ST(i), b=ST0.
  // `fdiv_err` (M6 Erratum 23): when 1, the div/divr group routes through the
  // SRT-flaw-aware divide (fx_div_errata); when 0 (default) it uses the exact
  // fx_div, so the clean core is bit-identical. add/sub/mul are never affected.
  function automatic logic [80:0] f_arith(input logic [2:0] sub,
                                          input logic [79:0] a, input logic [79:0] b,
                                          input logic [1:0] rc,
                                          input logic fdiv_err);
    unique case (sub)
      3'd0: f_arith = fx_add(a, b, rc);                       // add
      3'd1: f_arith = fx_mul(a, b, rc);                       // mul
      3'd4: f_arith = fx_add(a, {~b[79], b[78:0]}, rc);       // sub: a - b
      3'd5: f_arith = fx_add(b, {~a[79], a[78:0]}, rc);       // subr: b - a
      3'd6: f_arith = fdiv_err ? fx_div_errata(a, b, rc)
                               : fx_div(a, b, rc);            // div: a / b
      default: f_arith = fdiv_err ? fx_div_errata(b, a, rc)
                                  : fx_div(b, a, rc);         // divr: b / a
    endcase
  endfunction

  // The two arithmetic operands for the current x87 op, in the canonical
  // (dividend/divisor, minuend/subtrahend) order f_arith expects, so the
  // execute stage can pre-test them for the special cases QEMU handles
  // explicitly (0/0 -> QNaN+IE, x/0 -> Inf+ZE, sqrt(neg) -> QNaN+IE) WITHOUT
  // duplicating the per-form operand selection. `fa` is the left operand,
  // `fb` the right, matching f_arith(sub, fa, fb).
  function automatic logic f_div_by_zero(input logic [2:0] sub,
                                         input logic [79:0] a, input logic [79:0] b);
    // x/0 with x finite-nonzero. Only the div/divr group can zero-divide.
    unique case (sub)
      3'd6:    return fx_is_zero(b) && !fx_is_zero(a) && !fx_is_nan(a);  // a/b
      3'd7:    return fx_is_zero(a) && !fx_is_zero(b) && !fx_is_nan(b);  // b/a
      default: return 1'b0;
    endcase
  endfunction
  function automatic logic f_zero_over_zero(input logic [2:0] sub,
                                            input logic [79:0] a, input logic [79:0] b);
    unique case (sub)
      3'd6:    return fx_is_zero(a) && fx_is_zero(b);   // 0/0
      3'd7:    return fx_is_zero(a) && fx_is_zero(b);   // 0/0
      default: return 1'b0;
    endcase
  endfunction

  // Full arithmetic evaluation with the exception cases QEMU handles explicitly
  // for masked, default-control operands. Returns {ie, ze, inexact, result}:
  //   0/0          -> real-indefinite QNaN, IE                 (helper_fdiv)
  //   x/0 (x!=0)   -> signed Inf, ZE                           (helper_fdiv)
  //   otherwise    -> normal-operand datapath via f_arith, PE = inexact.
  // (a,b) are in f_arith canonical order: div = a/b, divr = b/a, etc.
  function automatic logic [82:0] f_eval(input logic [2:0] sub,
                                         input logic [79:0] a, input logic [79:0] b,
                                         input logic [1:0] rc,
                                         input logic fdiv_err);
    logic [80:0] r;
    logic [81:0] sp;
    begin
      sp = f_special(sub, a, b);
      if (sp[81])                                                // Inf/NaN special operand
        f_eval = {sp[80], 1'b0, 1'b0, sp[79:0]};                // {ie, ze=0, inexact=0, result}
      else if (f_zero_over_zero(sub, a, b))
        f_eval = {1'b1, 1'b0, 1'b0, 80'hFFFFC000000000000000};   // IE, indefinite
      else if (f_div_by_zero(sub, a, b)) begin
        r = f_arith(sub, a, b, rc, fdiv_err);                   // fx_div -> signed Inf
        f_eval = {1'b0, 1'b1, 1'b0, r[79:0]};                   // ZE
      end else begin
        r = f_arith(sub, a, b, rc, fdiv_err);
        f_eval = {1'b0, 1'b0, r[80], r[79:0]};                  // PE = inexact
      end
    end
  endfunction

  // Latch arithmetic status flags (sticky) into fstat from f_eval's flag bits.
  function automatic logic [15:0] f_arith_fstat(input logic [15:0] cur,
                                                input logic [82:0] arf);
    logic [15:0] r;
    begin
      r = cur;
      if (arf[82]) r[0] = 1'b1;   // IE
      if (arf[81]) r[2] = 1'b1;   // ZE
      if (arf[80]) r[5] = 1'b1;   // PE
      return r;
    end
  endfunction

endpackage : ventium_x87_pkg
