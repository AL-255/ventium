"""Private divide-input exponent experiment; no register/latency change.

The effective encoded exponent is 1..32767. Subtracting the bias and a
0..63 normalization shift gives -16445..16384, within signed 16-bit range.
Keep the existing signed 32-bit ua/ub registers and all arithmetic consumers.
"""
import hashlib

PARENT = '76cb1b6cde27b18f230286d706bf0383f7989a8848fe57ef439f024258ad0c7f'
PACKAGE = 'ae0b7bdb71e8c3450a7704a70c4742cf04eba4cc17c7e82aba40361855c59a01'
ANCHOR = '  // ---- result --------------------------------------------------------------\n'
HELPER = '''  // Divide normalization exponent is bounded: -16445..16384.
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

'''
OLD = '''                automatic logic [63:0] ma_ = fx_man(a);
                automatic logic [63:0] mb_ = fx_man(b);
                automatic int          ka  = 63;
                automatic int          kb  = 63;
                automatic logic signed [31:0] uae = fx_uexp_eff(a);
                automatic logic signed [31:0] ube = fx_uexp_eff(b);
                ka = 63 - int'(srt_input_clz64(ma_));
                kb = 63 - int'(srt_input_clz64(mb_));
                ma_  = ma_ << (63-ka);
                mb_  = mb_ << (63-kb);
                ua   <= uae - (63 - ka);
                ub   <= ube - (63 - kb);
'''
NEW = '''                automatic logic [63:0] ma_ = fx_man(a);
                automatic logic [63:0] mb_ = fx_man(b);
                automatic logic [5:0] lza = srt_input_clz64(ma_);
                automatic logic [5:0] lzb = srt_input_clz64(mb_);
                ma_  = ma_ << lza;
                mb_  = mb_ << lzb;
                ua   <= srt_div_input_exp(a[78:64], lza);
                ub   <= srt_div_input_exp(b[78:64], lzb);
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('divide exponent predecessor drift/reapplication')
    if source.count(OLD) != 1 or source.count(ANCHOR) != 1:
        raise ValueError('divide exponent ambiguous source anchor')
    return source.replace(OLD, NEW).replace(ANCHOR, HELPER+ANCHOR)


def proof(mutation=None):
    """All 15-bit exponent / 6-bit shift pairs, not whole RTL temporal proof."""
    effective = '(ite (= e (_ bv0 15)) (_ bv1 15) e)'
    if mutation == 'zero-bias': effective = 'e'
    width = 15 if mutation == 'too-narrow' else 16
    exponent = 'effective' if width == 15 else '((_ zero_extend 1) effective)'
    adjust = f'(bvsub (bvsub {exponent} (_ bv16383 {width})) ((_ zero_extend {width-6}) s))'
    extend = 'zero_extend' if mutation == 'unsigned' else 'sign_extend'
    return '\n'.join([
        '(set-logic QF_BV)', '(declare-const e (_ BitVec 15))', '(declare-const s (_ BitVec 6))',
        '(define-fun old () (_ BitVec 32) (bvsub (ite (= e (_ bv0 15)) (_ bv4294950914 32)',
        ' (bvsub ((_ zero_extend 17) e) (_ bv16383 32))) ((_ zero_extend 26) s)))',
        f'(define-fun effective () (_ BitVec 15) {effective})',
        f'(define-fun narrow () (_ BitVec {width}) {adjust})',
        f'(define-fun new () (_ BitVec 32) ((_ {extend} {32-width}) narrow))',
        '(assert (not (= old new)))', '(check-sat)',
    ])+'\n'
