"""Integer-only expected FPREM->FADD results proving original PC is restored."""
import struct


def cases():
    rows=[]
    for kind in (0,1):
        for pc,bits in ((0,24),(2,53),(3,64)):
            for rc in range(4):
                for sign in (0,1):
                    for bit in (2,32):
                        rows.append(dict(id=len(rows),kind=kind,
                            cw=0x7f|(pc<<8)|(rc<<10),sw=0x3000,
                            a=(0x3fff|(sign<<15),1<<63),
                            b=(0x4000|(sign<<15),(1<<63)|(1<<bit)),
                            bits=bits,rc=rc,sign=sign,bit=bit))
    return rows


def expected(row):
    # A=+/-1, B=+/-(2+epsilon), so either remainder is A (quotient zero).
    # The following FADD is +/-(3+epsilon); no precision-setting instruction
    # may occur between FPREM and FADD, even an apparently benign FRSTOR.
    exact=(3<<62)+(1<<row['bit']);unit=1<<(64-row['bits'])
    q,r=divmod(exact,unit)
    increment=bool(r) and (row['rc']==1 and row['sign'] or
                          row['rc']==2 and not row['sign'] or
                          row['rc']==0 and (2*r>unit or (2*r==unit and q&1)))
    return (0x4000|(row['sign']<<15),(q+increment)*unit),bool(r),bool(increment)


def grade(rows,raw):
    assert len(raw)==32*len(rows)
    errors=[]
    for row in rows:
        offset=32*row['id']
        ident,cw,rem_sw,add_sw,reserved=struct.unpack_from('<I4H',raw,offset)
        assert ident==row['id'] and reserved==0
        rem_lo,rem_hi,add_lo,add_hi=struct.unpack_from('<QHQH',raw,offset+12)
        value,pe,c1=expected(row);reasons=[]
        if cw!=row['cw']:reasons.append('control_changed')
        if (rem_hi,rem_lo)!=row['a']:reasons.append('wrong_remainder')
        if rem_sw!=row['sw']:reasons.append('wrong_remainder_status')
        if (add_hi,add_lo)!=value:reasons.append('precision_not_restored')
        if add_sw!=row['sw']|(int(pe)<<5)|(int(c1)<<9):reasons.append('wrong_add_status')
        if reasons:errors.append(dict(id=ident,reasons=reasons,rem=(rem_hi,rem_lo),
            sum=(add_hi,add_lo),rem_sw=rem_sw,add_sw=add_sw,expected_sum=value))
    return dict(passed=not errors,cases=len(rows),errors=errors)
