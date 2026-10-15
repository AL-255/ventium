"""Exact finite FPREM underflow oracle, Intel 241430-004 pp. 7-26/25-122..125.

All cases complete in one instruction. Values are integers in minimum-x80
subnormal units, so neither host floats nor the implementation set expectations.
UM=0 scales a nonzero tiny stack result by 2**24576 and raises UE, even if exact.
Condition bits on numeric underflow are recorded but not used as this oracle.
"""
import struct

import oracle
import state_vectors as state


def pairs():
    normal=(1,1<<63)
    result=[(f'normal-cancel-bit-{k}',(1,(1<<63)+(1<<k)),normal) for k in range(63)]
    result.extend([
        ('nearest-negative-ulp',normal,(1,(1<<63)+1)),
        ('maximum-denormal',(0,(1<<63)-1),normal),
        ('minimum-denormal',(0,1),normal),
        ('tiny-zero-quotient',(0,3),(0x4000,1<<63)),
        ('tiny-exact-zero',(0,3),(0,1)),
        ('tiny-remainder',(0,7),(0,3)),
        ('tiny-nearest-negative',(0,5),(0,3)),
        ('normal-exact-zero',normal,normal),
        ('normal-zero-quotient',(2,1<<63),(3,1<<63)),
        ('normal-largest-remainder',(1,(1<<64)-1),normal),
        ('pseudo-normal',(0,1<<63),(2,1<<63)),
    ])
    return result


def rows():
    result=[]
    for label,a,b in pairs():
        for op in (0,1):
            for mask in (0x3f,0x2f,0x3d,0x2d):
                for variant in range(12):
                    pc=(0,2,3)[variant%3];rc=variant//3
                    top=(0,3,7)[variant%3]
                    av=(a[0]|((variant&1)<<15),a[1])
                    bv=(b[0]|(((variant>>1)&1)<<15),b[1])
                    tw=(state.tag(av)<<(2*top))|(state.tag(bv)<<(2*((top+1)%8)))
                    # Never seed an already unmasked exception before FRSTOR.
                    sw=(top<<11)|(0x4724 if variant&1 else 0)
                    result.append(dict(label=label,op=op,a=av,b=bv,
                        cw=0x40|mask|(pc<<8)|(rc<<10),sw=sw,tag=tw))
    return result


def integer(v):
    e,m=v
    return (-m if e&0x8000 else m) << (max(e&0x7fff,1)-1)


def encode(n,zero_sign=0,wrapped=False):
    sign=0x8000 if n<0 else zero_sign if n==0 else 0
    n=abs(n)
    if not n:return sign,0
    bits=n.bit_length()
    if wrapped:
        assert bits<64
        return sign|(bits-63+24576),n<<(64-bits)
    if bits<64:return sign,n
    shift=bits-64
    assert n&((1<<shift)-1)==0
    return sign|(shift+1),n>>shift


def expected(r):
    assert oracle.exponent(r['a'])-oracle.exponent(r['b'])<64
    de=any((v[0]&0x7fff)==0 and v[1] for v in (r['a'],r['b']))
    aborted=de and not r['cw']&2
    n,q=oracle.final(integer(r['a']),integer(r['b']),r['op']==1)
    tiny=0<abs(n)<(1<<63)
    underflow=tiny and not r['cw']&16 and not aborted
    value=tuple(r['a']) if aborted else encode(n,r['a'][0]&0x8000,underflow)
    raised=(2 if de else 0)|(16 if underflow else 0)
    sw=(r['sw']&0x387f)|raised|(0x8080 if aborted or underflow else 0)
    # Complete nonfaulting quotient bits are defined; operand-abort/underflow
    # CCs are not required by this scoped oracle. The earlier diagnostic
    # overconstrained abort C2 (168 native mismatches); retain that raw run.
    # This matches state_vectors.status_mask, not a global trace-mask change.
    if aborted:sw|=r['sw']&0x4500
    elif not underflow:sw|=oracle.quotient_bits(q)
    mask=0xb8ff if underflow or aborted else 0xffff
    top=(r['sw']>>11)&7
    tag=(r['tag']&~(3<<(2*top)))|(state.tag(value)<<(2*top))
    return dict(value=value,status=sw,status_mask=mask,tag=tag,
                underflow=bool(underflow),operand_abort=bool(aborted),quotient=q)


def check(r,raw):
    assert len(raw)==108
    words=struct.unpack('<27I',raw);want=expected(r);errors=[]
    if words[0]&0xffff!=r['cw']:errors.append('control')
    if (words[1]^want['status'])&want['status_mask']:errors.append('status')
    if words[2]&0xffff!=want['tag']:errors.append('tags')
    values=[struct.pack('<QH',want['value'][1],want['value'][0]),
            struct.pack('<QH',r['b'][1],r['b'][0])]
    values.extend(struct.pack('<QH',1<<63,0x4000+((255+i)&255)) for i in range(2,8))
    if raw[28:]!=b''.join(values):errors.append('stack_payloads')
    return errors
