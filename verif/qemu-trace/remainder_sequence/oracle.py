"""Integer-only FPREM/FPREM1 sequence oracle, Intel 241430-004 pp. 25-122..125.

Partial steps may choose any N in [32,63]. Never require native and QEMU to
use the same N or compare undefined partial-step quotient bits.
"""
import random
import struct


def decoded(high, low):
    assert high & 0x7fff != 0x7fff
    shift=max(high&0x7fff,1)-16383-63
    return (-low if high&0x8000 else low), shift


def aligned(*values):
    decoded_values=[decoded(*v) for v in values]
    shift=min(e for m,e in decoded_values)
    return [m << (e-shift) for m,e in decoded_values]


def exponent(value):
    m,e=decoded(*value)
    return abs(m).bit_length()-1+e if m else -32768


def quotient_bits(q):
    return ((q&4)<<6)|((q&2)<<13)|((q&1)<<9)


def final(a,b,nearest):
    q,r=divmod(abs(a),abs(b))
    if nearest and (2*r>abs(b) or (2*r==abs(b) and q&1)):
        q+=1
    return a-(-1 if a<0 else 1)*q*abs(b),q


def step_errors(a,b,result,status,nearest):
    errors=[]
    ai,bi,ri=aligned(a,b,result)
    gap=exponent(a)-exponent(b)
    if a[1] and gap>=64:
        if not status&0x400: errors.append('missing_partial_c2')
        possible=[]
        for n in range(32,64):
            modulus=abs(bi) << (gap-n)
            expected=ai-(-1 if ai<0 else 1)*(abs(ai)//modulus)*modulus
            if expected==ri: possible.append(n)
        if not possible: errors.append('invalid_partial_value')
        if ri and exponent(result)>exponent(a)-32: errors.append('insufficient_progress')
    else:
        if status&0x400: errors.append('unexpected_partial_c2')
        expected,q=final(ai,bi,nearest)
        if ri!=expected: errors.append('wrong_complete_value')
        if status&0x4300 != quotient_bits(q): errors.append('wrong_complete_quotient')
    if not ri and (result[0]&0x8000)!=(a[0]&0x8000): errors.append('wrong_zero_sign')
    # Every fixture starts with normal finite operands and masked exceptions.
    # A later denormal operand may set DE; PE is never allowed for exact remainder.
    if status&0x80fd: errors.append('unexpected_exception')
    return errors


def cases():
    pairs=[]
    for gap in (-2,-1,0,1,62,63,64,65,95,96,127,128,255,1023,4095,8191,16383,32760):
        eb=max(1,16383-max(gap,0));ea=eb+gap
        for ma,mb in ((5<<61,1<<63),((1<<64)-1,0xb123456789abcdef),
                      (0x923456789abcdef1,0x8000000000000001)):
            pairs.append(((ea,ma),(eb,mb)))
    rng=random.Random(0xf9e2)
    for _ in range(24):
        gap=rng.choice((0,1,63,64,65,127,128,511))
        eb=rng.choice((1,2,100,16000,32000-gap))
        pairs.append(((eb+gap,(1<<63)|rng.getrandbits(63)),
                      (eb,(1<<63)|rng.getrandbits(63))))
    rows=[]
    for kind in (0,1):
        for pc in (0,2,3):
            for rc in range(4):
                for a,b in pairs:
                    for sa,sb in ((0,0),(0,1),(1,0),(1,1)):
                        rows.append(dict(id=len(rows),kind=kind,cw=0x7f|(pc<<8)|(rc<<10),
                            sw=0x3000|(0x4700 if len(rows)&1 else 0),
                            a=(a[0]|(sa<<15),a[1]),b=(b[0]|(sb<<15),b[1])))
    return rows


def grade(rows,raw):
    assert len(raw)%116==0
    records=[raw[i:i+116] for i in range(0,len(raw),116)]
    errors=[]; steps={}; previous={}; partial=0; finished=set()
    for data in records:
        ident,step=struct.unpack_from('<2I',data)
        assert ident<len(rows) and step==steps.get(ident,0) and ident not in finished
        row=rows[ident];steps[ident]=step+1
        assert not any(i>ident for i in steps)
        cw,sw,tag=struct.unpack_from('<3I',data,8)
        values=[(struct.unpack_from('<H',data,8+28+10*i+8)[0],
                 struct.unpack_from('<Q',data,8+28+10*i)[0]) for i in range(8)]
        incoming=previous.get(ident,row['a'])
        reasons=step_errors(incoming,row['b'],values[0],sw,row['kind']==1)
        if cw&0xffff!=row['cw']: reasons.append('control_changed')
        if sw&0x3800 != row['sw']&0x3800: reasons.append('top_changed')
        expected_rest=[row['b'],*[(0x3fff+i,1<<63) for i in range(2,8)]]
        if values[1:]!=list(map(tuple,expected_rest)): reasons.append('other_stack_payload_changed')
        expected_tag=1 if values[0][1]==0 else 2 if values[0][0]&0x7fff==0 else 0
        if tag&0xffff!=expected_tag<<12: reasons.append('tag_changed')
        if sw&0x400: partial+=1
        else:
            finished.add(ident)
            ai,bi,ri=aligned(row['a'],row['b'],values[0])
            expected,q=final(ai,bi,row['kind']==1)
            if ri!=expected: reasons.append('wrong_total_remainder')
            if sw&0x4300!=quotient_bits(q): reasons.append('wrong_total_quotient')
        if reasons: errors.append(dict(id=ident,step=step,reasons=reasons,
            incoming=incoming,result=values[0],status=sw&0xffff))
        previous[ident]=values[0]
    assert set(steps)==finished==set(range(len(rows)))
    return dict(cases=len(rows),records=len(records),partial_steps=partial,
                max_steps=max(steps.values()),errors=errors,passed=not errors)
