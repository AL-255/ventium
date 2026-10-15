"""Architectural partial-remainder set, allowing every Intel-permitted N=32..63.

All non-aborted results in this matrix are nonzero and tiny for EVERY legal N.
Do not require native x87, QEMU and SRT to choose the same partial-reduction N.
"""
import struct
import oracle
import state_vectors as state
import underflow_vectors as exact


def rows():
    result = []
    for exponent in (4,5,16,28,29):
        for denominator in (3,5,7):
            for low in (1,0x1234567):
                mantissa = (1<<63)+low
                while mantissa % denominator == 0: mantissa += 1
                for op in (0,1):
                    for mask in (0x3f,0x2f,0x3d,0x2d):
                        for variant in range(12):
                            top = (0,3,7)[variant%3]
                            a = (exponent|((variant&1)<<15),mantissa)
                            b = (((variant>>1)&1)<<15,denominator)
                            result.append(dict(label=f'partial-e{exponent}-d{denominator}-lo{low}',
                                op=op,a=a,b=b,cw=0x40|mask|((0,2,3)[variant%3]<<8)|((variant//3)<<10),
                                sw=(top<<11)|(0x4724 if variant&1 else 0),tag=2<<(2*((top+1)%8))))
    assert len(result) == 2880
    return result


def expected(r):
    ai,bi = exact.integer(r['a']),exact.integer(r['b'])
    gap = oracle.exponent(r['a'])-oracle.exponent(r['b'])
    assert gap >= 64
    partial = set()
    for n in range(32,64):
        modulus = abs(bi) << (gap-n)
        value = ai-(-1 if ai<0 else 1)*(abs(ai)//modulus)*modulus
        assert 0 < abs(value) < 1<<63
        partial.add(value)
    abort = not r['cw']&2
    underflow = not abort and not r['cw']&16
    values = {tuple(r['a'])} if abort else {exact.encode(n,wrapped=underflow) for n in partial}
    flags = 2 | (16 if underflow else 0)
    sw = (r['sw']&0x387f) | flags | (0x8080 if abort or underflow else 0)
    if not abort and not underflow: sw |= 0x400
    return dict(values=values,status=sw,status_mask=0xb8ff|(0x400 if not abort and not underflow else 0),
                abort=bool(abort),underflow=bool(underflow),gap=gap,legal_remainders=len(partial))


def check(r, raw):
    assert len(raw) == 108
    e = expected(r); errors = []
    cw,sw,tag = struct.unpack_from('<3I',raw)
    if cw&0xffff != r['cw']: errors.append('control')
    if (sw^e['status'])&e['status_mask']: errors.append('status')
    mantissa,exponent = struct.unpack_from('<QH',raw,28)
    value = (exponent,mantissa)
    if value not in e['values']: errors.append('invalid_partial_or_scaling')
    top = (r['sw']>>11)&7
    wanted_tag = (r['tag']&~(3<<(2*top))) | (state.tag(value)<<(2*top))
    if tag&0xffff != wanted_tag: errors.append('tags')
    rest = [r['b'],*[(0x4000+((255+i)&255),1<<63) for i in range(2,8)]]
    if raw[38:] != b''.join(struct.pack('<QH',v[1],v[0]) for v in rest): errors.append('other_stack')
    return errors
