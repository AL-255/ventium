"""Exact-parent FPREM operand exceptions; preserve the precision-only repair."""
import hashlib

HELPER = 'target/i386/tcg/fpu_helper.c'
PARENT_SHA = 'fdc2ec4c43de43ed7a72bc2ce7e5288597a5f15994021c7d24715b56218dfc35'


def transform(text):
    if hashlib.sha256(text.encode()).hexdigest() != PARENT_SHA:
        raise ValueError('FPREM exception parent drift or repeated application')
    first = text.index('static void helper_fprem_common(')
    last = text.index('\nvoid helper_fprem1(', first)
    before = text[first:last]
    anchor = '    exp1 = EXPD(temp1);\n'
    addition = '''
    /* Stack/unsupported/SNaN precede QNaN, other invalids, then DE.
     * Unmasked operand exceptions must not change the destination. */
    env->fpus &= ~0x0200;
    if (env->fptags[env->fpstt] || env->fptags[(env->fpstt + 1) & 7]) {
        fpu_set_exception(env, FPUS_IE | FPUS_SF);
        if (env->fpuc & FPUS_IE) {
            ST0 = floatx80_default_nan(&env->fp_status);
            env->fptags[env->fpstt] = 0;
            env->fpus &= ~0x0400;
        }
        goto done;
    }
    if (floatx80_invalid_encoding(ST0) || floatx80_invalid_encoding(ST1) ||
        floatx80_is_signaling_nan(ST0, &env->fp_status) ||
        floatx80_is_signaling_nan(ST1, &env->fp_status)) {
        float_raise(float_flag_invalid, &env->fp_status);
        if (!(env->fpuc & FPUS_IE)) {
            goto done;
        }
    } else if (!floatx80_is_any_nan(ST0) && !floatx80_is_any_nan(ST1)) {
        if (floatx80_is_infinity(ST0) || floatx80_is_zero(ST1)) {
            float_raise(float_flag_invalid, &env->fp_status);
            if (!(env->fpuc & FPUS_IE)) {
                goto done;
            }
        } else if ((exp0 == 0 && temp0.l.lower != 0) ||
                   (exp1 == 0 && temp1.l.lower != 0)) {
            float_raise(float_flag_input_denormal, &env->fp_status);
            if (!(env->fpuc & FPUS_DE)) {
                goto done;
            }
        }
    }
'''
    finish = '    set_floatx80_rounding_precision(precision, &env->fp_status);\n'
    if before.count(anchor) != 1 or before.count(finish) != 1:
        raise ValueError('FPREM exception boundary drift')
    after = before.replace(anchor, anchor+addition).replace(finish, 'done:\n'+finish)
    return text[:first]+after+text[last:]
