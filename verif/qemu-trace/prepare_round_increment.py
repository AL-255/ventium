"""Private QEMU round-pack event; no architectural C1 or oracle promotion.

Observe whether the LAST format-rounding step increments the truncated
significand's magnitude. It is not sticky, not a new exception, and not yet
defined for conversions to integers. No numerical result or exception changes.
"""
import hashlib

PARENTS = {
    'include/fpu/softfloat-types.h': 'f24eb2957c186cb1c9fe6b6f78f5880e2edf9dd3d341605431db470014f13bd2',
    'fpu/softfloat-parts.c.inc': 'ed281258f2a96800fa41b90f913ba817e6f052095995c7bfca231a4136ffd2d8',
    'fpu/softfloat.c': '52bfcaccf667d11d4fbb79a0d51d62ce6362417f5a47043da0a20a0d7395f3fa',
}


def change(text, old, new, count=1):
    if text.count(old) != count:
        raise ValueError('round event anchor drift: '+old)
    return text.replace(old,new)


def transform(inputs):
    if set(inputs) != set(PARENTS):
        raise ValueError('need all round-event sources')
    for name, digest in PARENTS.items():
        if hashlib.sha256(inputs[name].encode()).hexdigest() != digest:
            raise ValueError('round-event parent drift/reapplication: '+name)
    out = dict(inputs)
    name = 'include/fpu/softfloat-types.h'
    out[name] = change(out[name], '    bool rebias_underflow;\n', '''    bool rebias_underflow;
    /* Ventium diagnostic derivative: last round-pack magnitude increment.
     * Not sticky, not an exception, and not an integer-conversion result.
     * No x86 architectural flag consumes this field in this proposal.
     */
    bool float_round_increment;
''')
    name = 'fpu/softfloat-parts.c.inc'
    text = out[name]
    text = change(text, '    int exp, flags = 0;\n',
                  '    int exp, flags = 0;\n\n    s->float_round_increment = false;\n')
    # An increment constant need not increment a retained bit: nearest rounding
    # below half adds a nonzero constant but only changes discarded bits.
    text = change(text, '\n            flags |= float_flag_inexact;\n',
        '\n            s->float_round_increment =\n'
        '                inc > round_mask - (p->frac_lo & round_mask);\n'
        '            flags |= float_flag_inexact;\n', 3)
    text = change(text, '                flags = float_flag_invalid;\n',
                  '                s->float_round_increment = false;\n                flags = float_flag_invalid;\n')
    text = change(text, '            } else if (overflow_norm) {\n',
                  '            } else if (overflow_norm) {\n                s->float_round_increment = false;\n')
    text = change(text, '                p->cls = float_class_inf;\n',
                  '                s->float_round_increment = true;\n                p->cls = float_class_inf;\n')
    text = change(text, '''{
    if (likely(p->cls == float_class_normal)) {
        parts_uncanon_normal(p, s, fmt);''', '''{
    s->float_round_increment = false;
    if (likely(p->cls == float_class_normal)) {
        parts_uncanon_normal(p, s, fmt);''')
    out[name] = text
    name = 'fpu/softfloat.c'
    # x80 uses a separate packing switch for its explicit integer bit; zero,
    # NaN and infinity must not retain the preceding event either.
    out[name] = change(out[name], '''    const FloatFmt *fmt = &floatx80_params[s->floatx80_rounding_precision];
    uint64_t frac;
    int exp;

    switch (p->cls) {''', '''    const FloatFmt *fmt = &floatx80_params[s->floatx80_rounding_precision];
    uint64_t frac;
    int exp;

    s->float_round_increment = false;
    switch (p->cls) {''')
    return out
