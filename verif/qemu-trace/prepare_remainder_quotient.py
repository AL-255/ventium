"""Private QEMU FPREM1 quotient repair; canonical sources remain untouched.

Separate the modulus/remainder choice from the optional quotient output.
Previously a non-NULL output implicitly selected truncation, so the x80
nearest-remainder wrapper had to discard the quotient entirely.
"""
import hashlib

PARENTS = {
    'fpu/softfloat.c': '52bfcaccf667d11d4fbb79a0d51d62ce6362417f5a47043da0a20a0d7395f3fa',
    'fpu/softfloat-parts.c.inc': 'ed281258f2a96800fa41b90f913ba817e6f052095995c7bfca231a4136ffd2d8',
}


def change(text, old, new, count=1):
    if text.count(old) != count:
        raise ValueError('remainder quotient anchor drift: '+old)
    return text.replace(old, new)


def transform(inputs):
    if set(inputs) != set(PARENTS):
        raise ValueError('need exactly the remainder sources')
    for name, digest in PARENTS.items():
        if hashlib.sha256(inputs[name].encode()).hexdigest() != digest:
            raise ValueError('remainder parent drift/reapplication: '+name)
    out = dict(inputs)
    text = out['fpu/softfloat.c']
    for spaces in (36, 38):
        old = '\n'+' '*spaces+'uint64_t *mod_quot, float_status *s);'
        text = change(text, old, '\n'+' '*spaces+'bool mod, uint64_t *mod_quot, float_status *s);')
    text = change(text, '#define parts_modrem(A, B, Q, S)', '#define parts_modrem(A, B, M, Q, S)')
    text = change(text, 'PARTS_GENERIC_64_128(modrem, A)(A, B, Q, S)',
        'PARTS_GENERIC_64_128(modrem, A)(A, B, M, Q, S)')
    text = change(text,
        'static void frac64_modrem(FloatParts64 *a, FloatParts64 *b, uint64_t *mod_quot)',
        'static void frac64_modrem(FloatParts64 *a, FloatParts64 *b,\n'
        '                           bool mod, uint64_t *mod_quot)')
    text = change(text, '                           uint64_t *mod_quot)\n',
        '                           bool mod, uint64_t *mod_quot)\n')
    # The loop's estimated digit is at bit exp_diff, not at the low end of
    # an integer radix-2^61/62 digit stream. The old quotient accumulation
    # gave wrong low bits above the first 64-bit step, even for modulus.
    text = change(text, '    exp_diff -= 64;\n    while (exp_diff > 0) {\n',
        '    quot = exp_diff < 64 ? quot << exp_diff : 0;\n'
        '    exp_diff -= 64;\n    while (exp_diff > 0) {\n', 2)
    for stride in (61,62):
        text = change(text, f'        exp_diff -= {stride};\n'
            f'        quot = (quot << {stride}) + q;\n',
            '        if (exp_diff < 64) {\n'
            '            quot += q << exp_diff;\n'
            '        }\n'+f'        exp_diff -= {stride};\n')
    text = change(text, '        quot = (exp_diff < 64 ? quot << exp_diff : 0) + q;\n',
                  '        quot += q;\n', 2)
    text = change(text, '''    if (mod_quot) {
        *mod_quot = quot;
    } else {
''', '''    if (!mod) {
''', 2)
    # Only the remainder-choice complement changes quotient magnitude.
    # uint64_t wrap is deliberate: the public contract returns low 64 bits.
    for temp in ('            a1 = t1;\n', '            a2 = t2;\n'):
        text = change(text, temp+'            a->sign = !a->sign;\n',
            temp+'            a->sign = !a->sign;\n            ++quot;\n')
    text = change(text, '''    }

    if (likely(a0)) {
        shift = clz64(a0);
''', '''    }
    if (mod_quot) {
        *mod_quot = quot;
    }

    if (likely(a0)) {
        shift = clz64(a0);
''', 2)
    text = change(text,
        '#define frac_modrem(A, B, Q)  FRAC_GENERIC_64_128(modrem, A)(A, B, Q)',
        '#define frac_modrem(A, B, M, Q)  FRAC_GENERIC_64_128(modrem, A)(A, B, M, Q)')
    text = change(text, 'parts_modrem(&pa, &pb, NULL, status)',
        'parts_modrem(&pa, &pb, false, NULL, status)', 3)
    text = change(text, 'parts_modrem(&pa, &pb, mod ? quotient : NULL, status)',
        'parts_modrem(&pa, &pb, mod, quotient, status)')
    text = change(text, ''' * the remainder based on truncating the quotient toward zero instead and
 * *quotient is set to the low 64 bits of the absolute value of the integer
 * quotient.
''', ''' * the remainder based on truncating the quotient toward zero instead.
 * In both modes, *quotient is set to the low 64 bits of the absolute value
 * of the integer quotient (nearest-even when mod is false).
''')
    out['fpu/softfloat.c'] = text
    text = out['fpu/softfloat-parts.c.inc']
    text = change(text, '                                   uint64_t *mod_quot, float_status *s)\n',
        '                                   bool mod, uint64_t *mod_quot, float_status *s)\n')
    text = change(text, 'frac_modrem(a, b, mod_quot);', 'frac_modrem(a, b, mod, mod_quot);')
    out['fpu/softfloat-parts.c.inc'] = text
    return out
