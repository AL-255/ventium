"""Exact-parent, instruction-local FPREM precision repair for private QEMU."""
import hashlib

HELPER = 'target/i386/tcg/fpu_helper.c'
PARENT_SHA = '77e0483d8d7522380376bf125dba3c6aac5f7855a7003f65d5d9a66d6f7f78ff'
START = 'static void helper_fprem_common(CPUX86State *env, bool mod)\n'
END = '\nvoid helper_fprem1(CPUX86State *env)\n'


def transform(text):
    if hashlib.sha256(text.encode()).hexdigest() != PARENT_SHA:
        raise ValueError('FPREM parent drift or repeated application')
    if text.count(START) != 1 or text.count(END) != 1:
        raise ValueError('FPREM helper boundary drift')
    first = text.index(START); last = text.index(END, first)
    before = text[first:last]
    declarations = '    int exp0, exp1, expdiff;\n'
    begin = '    env->fpus &= ~0x4700; /* (C3,C2,C1,C0) <-- 0000 */\n'
    finish = '    merge_exception_flags(env, old_flags);\n'
    if any(before.count(anchor) != 1 for anchor in (declarations, begin, finish)):
        raise ValueError('FPREM helper interior drift')
    if 'return' in before or 'goto' in before:
        raise ValueError('FPREM helper no longer has one exit')
    after = before.replace(declarations, declarations +
        '    FloatX80RoundPrec precision = env->fp_status.floatx80_rounding_precision;\n')
    after = after.replace(begin,
        '    /* FPREM/FPREM1 are exact: PC must not round either the scaled\n'
        '     * divisor or the remainder. Restore PC for the next instruction. */\n'
        '    set_floatx80_rounding_precision(floatx80_precision_x, &env->fp_status);\n' + begin)
    after = after.replace(finish,
        '    set_floatx80_rounding_precision(precision, &env->fp_status);\n' + finish)
    return text[:first] + after + text[last:]
