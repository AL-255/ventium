"""Private-reference FPREM exact tiny-result response; no global FP policy change."""
import hashlib

HELPER='target/i386/tcg/fpu_helper.c'
PARENT_SHA='023871dba80edeb59fe7c814696e6d8d8d45406cc97760c706e8ca2b3f1b61a2'
ADDITION='''    /* Exact FPREM may still underflow when UM=0 (Intel 241430-004,
     * section 7.1.12.2). The stack response is scaled by 2**24576.
     * Operand-abort jumps skip this block; zero and pseudo-normal results
     * are not tiny. Keep extended precision until after the rescaling. */
    if (!(env->fpuc & FPUS_UE) && extractFloatx80Exp(ST0) == 0 &&
        extractFloatx80Frac(ST0) != 0 &&
        !(extractFloatx80Frac(ST0) & (UINT64_C(1) << 63))) {
        ST0 = floatx80_scalbn(ST0, 24576, &env->fp_status);
        float_raise(float_flag_underflow, &env->fp_status);
    }
'''


def transform(text):
    if hashlib.sha256(text.encode()).hexdigest()!=PARENT_SHA:
        raise ValueError('FPREM underflow parent drift or repeated application')
    first=text.index('static void helper_fprem_common(')
    last=text.index('\nvoid helper_fprem1(',first)
    before=text[first:last]
    anchor='done:\n    set_floatx80_rounding_precision(precision, &env->fp_status);'
    if before.count(anchor)!=1:raise ValueError('FPREM underflow completion drift')
    after=before.replace(anchor,ADDITION+anchor)
    return text[:first]+after+text[last:]
