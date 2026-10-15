"""Directed FPREM exception classes, with instruction-specific priority.

UM stays masked: unmasked tiny-result rescaling is a separate qualification.
No undefined condition-code bit is used as an exception oracle.
"""
import struct

VALUES = {
    'zero': (0, 0), 'small': (0x3fff, 0xc000000000000000),
    'two': (0x4000, 1 << 63), 'tiny': (0, 3),
    'pseudo': (0, (1 << 63) + 3), 'minnorm': (1, (1 << 63) + 3),
    'inf': (0x7fff, 1 << 63), 'qnan': (0x7fff, 0xc123456789abcdef),
    'qnan_big': (0x7fff, 0xf123456789abcdef),
    'snan': (0x7fff, 0xa23456789abcdef1),
    'snan_big': (0x7fff, 0xb23456789abcdef1),
    'unnormal': (0x3fff, 0x4000000000000000),
    'pseudo_nan': (0x7fff, 0x4000000000000000),
    'pseudo_inf': (0x7fff, 0),
}


def classify(v):
    e, m = v; e &= 0x7fff
    if e and not m >> 63: return 'unsupported'
    if e == 0x7fff:
        if m == 1 << 63: return 'inf'
        return 'qnan' if m & (1 << 62) else 'snan'
    if not e: return 'denormal' if m else 'zero'
    return 'normal'


def tag(v):
    return {'normal': 0, 'zero': 1}.get(classify(v), 2)


def rows():
    result = []
    for op in (0, 1):
        for an, a in VALUES.items():
            for bn, b in VALUES.items():
                for mask in (0x3f, 0x3e, 0x3d, 0x3c):
                    for variant in range(6):
                        pc = (0, 2, 3)[variant % 3]; rc = variant % 4
                        top = (0, 3, 7)[variant % 3]
                        av = (a[0] | (0x8000 if variant & 1 else 0), a[1])
                        bv = (b[0] | (0x8000 if variant & 2 else 0), b[1])
                        tw = (tag(av) << (2*top)) | (tag(bv) << (2*((top+1)%8)))
                        result.append(dict(op=op, a=av, b=bv, names=[an, bn],
                            cw=0x40 | mask | (pc << 8) | (rc << 10),
                            sw=(top << 11) | (0x4778 if variant & 1 else 0), tag=tw))
        for empty in (1, 2, 3):
            for top in (0, 3, 7):
                for mask in (0x3f, 0x3e, 0x3d, 0x3c):
                    for seed in (0, 0x4778):
                        # Empty stack has priority over unsupported/denormal.
                        a, b = VALUES['unnormal'], VALUES['tiny']
                        tw = ((3 if empty & 1 else tag(a)) << (2*top)) | \
                             ((3 if empty & 2 else tag(b)) << (2*((top+1)%8)))
                        result.append(dict(op=op, a=a, b=b, names=['empty', str(empty)],
                            cw=0x340 | mask, sw=(top << 11) | seed, tag=tw))
    return result


def pack(r):
    a, b = r['a'], r['b']
    return struct.pack('<10I', r['cw'], r['sw'], r['tag'], r['op'],
                       a[1] & 0xffffffff, a[1] >> 32, a[0],
                       b[1] & 0xffffffff, b[1] >> 32, b[0])


def flags(r):
    top = (r['sw'] >> 11) & 7
    if any(((r['tag'] >> (2*((top+i)%8))) & 3) == 3 for i in (0, 1)):
        return 0x41
    a, b = classify(r['a']), classify(r['b'])
    if 'unsupported' in (a, b) or 'snan' in (a, b): return 1
    if 'qnan' in (a, b): return 0
    if a == 'inf' or b == 'zero': return 1
    return 2 if 'denormal' in (a, b) else 0


def status_mask(r, sw):
    mask = 0xb8ff  # TOP, B, ES, SF and all six exception flags.
    raised = flags(r)
    abort = raised & ~r['cw'] & 3
    if raised & 0x40: mask |= 0x200  # Stack underflow C1=0.
    if not abort:
        # Quotient is undefined for NaNs/invalids and partial reductions.
        if raised & 1: mask |= 0x400  # Invalid remainder clears C2.
        elif all(classify(v) not in ('qnan', 'snan') for v in (r['a'], r['b'])):
            mask |= 0x400 if sw & 0x400 else 0x4700
    return mask


def check_native(r, raw):
    words = struct.unpack('<27I', raw); sw = words[1] & 0xffff
    raised = flags(r)
    expected = (r['sw'] & 0x7f) | raised
    if raised & ~r['cw'] & 3: expected |= 0x8080
    errors = []
    if sw & 0x80ff != expected: errors.append('exception_priority')
    if words[0] & 0xffff != r['cw']: errors.append('control')
    if sw & 0x3800 != r['sw'] & 0x3800: errors.append('top')
    if raised & ~r['cw'] & 3:
        expected_a = struct.pack('<QH', r['a'][1], r['a'][0])
        if raw[28:38] != expected_a: errors.append('unmasked_destination')
    if raw[38:48] != struct.pack('<QH', r['b'][1], r['b'][0]): errors.append('st1')
    for i in range(2, 8):
        if raw[28+10*i:38+10*i] != struct.pack('<QH', 1 << 63, 0x4000+((0xff+i)&0xff)):
            errors.append('other_slot_'+str(i))
    return errors


def compare(r, expected, actual):
    n = struct.unpack('<27I', expected); c = struct.unpack('<27I', actual)
    errors = []
    if (n[0] ^ c[0]) & 0xffff: errors.append('control')
    if (n[1] ^ c[1]) & status_mask(r, n[1]): errors.append('status')
    if (n[2] ^ c[2]) & 0xffff: errors.append('tags')
    if expected[28:] != actual[28:]: errors.append('stack_payloads')
    return errors
