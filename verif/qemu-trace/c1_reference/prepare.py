"""Compose qualified private SoftFloat changes and instruction-specific C1.

This derives a private reference, never mutates the canonical QEMU source.
Normal arithmetic C1 is the final retained-significand increment. Internal
temporary loads and generic pops must not clear an instruction's result.
"""
import difflib
import hashlib
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import prepare_round_increment as rounding
import prepare_remainder_quotient as remainder
from fp_env import prepare as environment

HELPER = 'target/i386/tcg/fpu_helper.c'


def replace(text, old, new, count=1):
    if text.count(old)!=count:
        raise ValueError('C1 anchor drift: '+old)
    return text.replace(old, new)


def merge(original, *variants):
    """Apply independent line edits against one exact common ancestor."""
    lines = original.splitlines(keepends=True)
    edits = []
    for variant in variants:
        other = variant.splitlines(keepends=True)
        for tag, lo, hi, newlo, newhi in difflib.SequenceMatcher(
                None, lines, other, autojunk=False).get_opcodes():
            if tag!='equal':
                edits.append((lo, hi, other[newlo:newhi]))
    edits.sort(key=lambda e: (e[0], e[1]))
    for first, second in zip(edits, edits[1:]):
        if first[1]>second[0] or first[0]==second[0]:
            raise ValueError('overlapping reference changes')
    for lo, hi, value in reversed(edits):
        lines[lo:hi] = value
    return ''.join(lines)


def helper_c1(text):
    if hashlib.sha256(text.encode()).hexdigest()!=environment.SOURCE_SHA:
        raise ValueError('C1 helper parent drift/reapplication')
    text = replace(text, 'static inline floatx80 helper_fdiv(', '''/* Final round-pack event, not a sticky exception flag or temporary result. */
static void vtm_fpu_round_c1(CPUX86State *env)
{
    env->fpus = (env->fpus & ~0x0200) |
                (env->fp_status.float_round_increment ? 0x0200 : 0);
}

static inline floatx80 helper_fdiv(''')
    def edit_function(source, name, edit):
        needle = name+'('
        pos = source.index(needle)
        assert source.count(needle)==1, name
        start = source.rfind('\n', 0, pos)+1
        end = source.index('\n}\n', pos)+3
        body = source[start:end]
        return source[:start]+edit(body)+source[end:]
    # helper_fdiv has callers, so update its unique round operation directly.
    text = replace(text, '    floatx80 ret = floatx80_div(a, b, &env->fp_status);\n',
        '    floatx80 ret = floatx80_div(a, b, &env->fp_status);\n'
        '    vtm_fpu_round_c1(env);\n')
    for name in ('fadd_ST0_FT0','fmul_ST0_FT0','fsub_ST0_FT0','fsubr_ST0_FT0',
                 'fadd_STN_ST0','fmul_STN_ST0','fsub_STN_ST0','fsubr_STN_ST0',
                 'fsqrt','fsts_ST0','fstl_ST0'):
        text = edit_function(text, 'helper_'+name, lambda body: replace(body,
            '    merge_exception_flags(env, old_flags);',
            '    vtm_fpu_round_c1(env);\n    merge_exception_flags(env, old_flags);'))
    # FLD/FILD helpers clear normal-load C1 after successful operand access,
    # before marking the destination occupied. Leave existing overflow policy
    # untouched: this reference stage does not repair QEMU stack exceptions.
    text = replace(text, '    env->fpstt = new_fpstt;\n',
        '    if (env->fptags[new_fpstt]) {\n'
        '        env->fpus &= ~0x0200;\n'
        '    }\n    env->fpstt = new_fpstt;\n', 5)
    text = edit_function(text, 'helper_fpush', lambda body: replace(body,
        '    fpush(env);',
        '    if (env->fptags[(env->fpstt - 1) & 7]) {\n'
        '        env->fpus &= ~0x0200;\n'
        '    }\n    fpush(env);'))
    for name in ('fmov_STN_ST0', 'fxchg_ST0_STN', 'fchs_ST0', 'fabs_ST0', 'fstt_ST0'):
        text = edit_function(text, 'helper_'+name, lambda body: replace(body,
            '\n}\n', '\n    env->fpus &= ~0x0200;\n}\n'))
    for name in ('fcom_ST0_FT0', 'fucom_ST0_FT0'):
        text = edit_function(text, 'helper_'+name,
                             lambda body: replace(body, '~0x4500', '~0x4700'))
    # FRNDINT's final pack is exact after the integer rounding step, so its
    # pack event is not the instruction's event. Compare input/result magnitude
    # with an isolated status copy; comparison exceptions cannot escape.
    text = edit_function(text, 'helper_frndint', lambda body: replace(replace(body,
        '    ST0 = floatx80_round_to_int(ST0, &env->fp_status);',
        '    floatx80 before = ST0;\n'
        '    float_status comparison;\n'
        '    ST0 = floatx80_round_to_int(ST0, &env->fp_status);\n'
        '    comparison = env->fp_status;\n'
        '    env->fpus = (env->fpus & ~0x0200) |\n'
        '        (floatx80_lt(floatx80_abs(before), floatx80_abs(ST0),\n'
        '                     &comparison) ? 0x0200 : 0);'),
        '\n}\n', '\n}\n'))
    return text


def transform(inputs):
    required = set(rounding.PARENTS)|set(remainder.PARENTS)|{HELPER}
    if set(inputs)!=required:
        raise ValueError('need complete C1 reference source set')
    a = rounding.transform({n:inputs[n] for n in rounding.PARENTS})
    b = remainder.transform({n:inputs[n] for n in remainder.PARENTS})
    out = {}
    for name in required-{HELPER}:
        variants = [v[name] for v in (a,b) if name in v]
        out[name] = merge(inputs[name], *variants)
    out[HELPER] = merge(inputs[HELPER], helper_c1(inputs[HELPER]),
                        environment.transform(inputs[HELPER]))
    return out
