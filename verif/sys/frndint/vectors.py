"""Integer-only FRNDINT oracle and architectural corner inputs."""
import random
import struct


def rows():
    values = {(0,0), (0,1), (0,0x7fffffffffffffff), (0,1<<63)}
    for e in (-16382,-65,-2,-1,0,1,2,23,24,31,32,52,53,61,62,63,64,16383):
        for m in (1<<63,(1<<63)+1,(1<<63)+(1<<61),3<<62,(1<<64)-2,(1<<64)-1):
            values.add((e+16383,m))
    rng=random.Random(0xD9FC)
    for _ in range(32): values.add((16383+rng.randrange(-3,65),(1<<63)|rng.getrandbits(63)))
    values |= {(0x7fff,1<<63),(0x7fff,0xc123456789abcdef),
               (0x7fff,0xa123456789abcdef),(0x3fff,0x4000000000000000),
               (0x7fff,0x4000000000000000)}
    result=[]
    for e,m in sorted(values):
        for sign in (0,0x8000):
            for pc in (0,2,3):
                for rc in range(4):
                    for seed in (0,1):
                        for mask in (0x3f,0x3e,0x3d,0x1f):
                            result.append(dict(cw=0x40|(pc<<8)|(rc<<10)|mask,
                                sw=0x4500|(seed<<9),tag=0,hi=e|sign,m=m,kind=0))
    # Directed empty-stack checks (masked and unmasked), all old C1 values.
    for mask in (0x3f,0x3e):
        for seed in (0,1):
            result.append(dict(cw=0x340|mask,sw=0x4500|(seed<<9),tag=3,
                               hi=0x3fff,m=1<<63,kind=0))
    # Adjacent service clients: avoid intentional invalid/range FIST cases.
    for kind in (1,2,3):
        for sign in (0,0x8000):
            for rc in range(4):
                for m in ((1<<63),3<<62,(1<<64)-1):
                    result.append(dict(cw=0x37f|(rc<<10),sw=0x4500,tag=0,
                                       hi=0x3fff|sign,m=m,kind=kind))
    return result


def pack(r):
    return struct.pack('<8I',r['cw'],r['sw'],r['tag'],r['hi'],
                       r['m']&0xffffffff,r['m']>>32,r['kind'],0)


def finite_result(r):
    """Independent exact normal/zero rounding; no host floating point."""
    e=r['hi']&0x7fff; m=r['m']; sign=r['hi']>>15
    if r['kind'] or r['tag'] or e==0x7fff or (e and not m>>63) or (not e and m):
        return None
    if e>=16383+63 or not m:
        return (r['hi']<<64)|m,0
    shift=63-(e-16383)
    whole,rem=divmod(m,1<<shift)
    rc=(r['cw']>>10)&3
    inc=bool(rem) and ((rc==0 and (rem*2>(1<<shift) or
        (rem*2==(1<<shift) and whole&1))) or (rc==1 and sign) or (rc==2 and not sign))
    whole+=int(inc)
    if whole:
        msb=whole.bit_length()-1
        value=((sign<<15)|(16383+msb))<<64 | (whole<<(63-msb))
    else: value=sign<<79
    flags=(0x20 if rem else 0)|(0x200 if inc else 0)
    if rem and not(r['cw']&0x20): flags|=0x8080
    return value,flags
