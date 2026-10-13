"""Instruction-local FRNDINT reference repair; never edit canonical QEMU."""
import hashlib

HELPER = 'target/i386/tcg/fpu_helper.c'
PARENT_SHA = 'b9727b725fb22b2162b2a07c2ec8388bcc8e404498f7fb4f3ae44906fe1adf7b'
BEFORE = '''void helper_frndint(CPUX86State *env)
{
    uint8_t old_flags = save_exception_flags(env);
    floatx80 before = ST0;
    float_status comparison;
    ST0 = floatx80_round_to_int(ST0, &env->fp_status);
    comparison = env->fp_status;
    env->fpus = (env->fpus & ~0x0200) |
        (floatx80_lt(floatx80_abs(before), floatx80_abs(ST0),
                     &comparison) ? 0x0200 : 0);
    merge_exception_flags(env, old_flags);
}
'''
AFTER = '''void helper_frndint(CPUX86State *env)
{
    uint8_t old_flags = save_exception_flags(env);
    floatx80 before = ST0;
    floatx80 rounded;
    float_status comparison;
    FloatX80RoundPrec precision = env->fp_status.floatx80_rounding_precision;

    env->fpus &= ~0x0200;
    if (env->fptags[env->fpstt]) {
        fpu_set_exception(env, FPUS_IE | FPUS_SF);
        if (env->fpuc & FPUS_IE) {
            ST0 = floatx80_default_nan(&env->fp_status);
            env->fptags[env->fpstt] = 0;
        }
        goto done;
    }
    if (floatx80_invalid_encoding(before) ||
        floatx80_is_signaling_nan(before, &env->fp_status)) {
        float_raise(float_flag_invalid, &env->fp_status);
        if (!(env->fpuc & FPUS_IE)) {
            goto done;
        }
    } else if (floatx80_is_zero_or_denormal(before) && before.low != 0) {
        /* Include pseudo-denormals. Unmasked DE precedes rounding/PE. */
        float_raise(float_flag_input_denormal, &env->fp_status);
        if (!(env->fpuc & FPUS_DE)) {
            goto done;
        }
    }
    /* FRNDINT obeys RC, not PC. Do not round the integer a second time. */
    set_floatx80_rounding_precision(floatx80_precision_x, &env->fp_status);
    rounded = floatx80_round_to_int(before, &env->fp_status);
    set_floatx80_rounding_precision(precision, &env->fp_status);
    comparison = env->fp_status;
    if (floatx80_lt(floatx80_abs(before), floatx80_abs(rounded), &comparison)) {
        env->fpus |= 0x0200;
    }
    ST0 = rounded;
done:
    merge_exception_flags(env, old_flags);
}
'''


def transform(text):
    if hashlib.sha256(text.encode()).hexdigest() != PARENT_SHA:
        raise ValueError('FRNDINT parent drift or repeated application')
    if text.count(BEFORE) != 1:
        raise ValueError('FRNDINT helper anchor drift')
    return text.replace(BEFORE, AFTER)
