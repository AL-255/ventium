#!/usr/bin/env python3
"""Reuse the checked paged/relocated boot prelude with an AGI-specific loop.

Four different operand values and addresses expose stale pre-writer GPR reads.
No timing expectations are embedded in the guest or QEMU oracle.
"""
from pathlib import Path

HERE=Path(__file__).resolve().parent


def once(text,old,new):
    if text.count(old)!=1:raise ValueError('missing/ambiguous fixture anchor: '+old)
    return text.replace(old,new)


def transform(text):
    start=text.index('hot_loop:\n')
    end=text.index('hot_end:\n',start)
    old=text[start:end]
    text=once(text,old,'''hot_loop:
    .irp displacement,0,64,128,192
#if KIND == 6
    // Unrelated write: ordinary load has no address dependency.
    leal \\displacement(%ebp),%edi
    movl \\displacement(%ebp),%eax
#elif KIND == 7
    // An AGI store is not a resident-read hint.
    leal \\displacement(%ebp),%edi
    movl %eax,(%edi)
#elif KIND == 8
    // Word and extending loads retain the reference execution path.
    leal \\displacement(%ebp),%edi
    movw (%edi),%ax
#elif KIND == 9
    leal \\displacement(%ebp),%edi
    movsbl (%edi),%eax
#elif KIND == 4
    // Scaled index is written on the immediately preceding issue clock.
    movl $(\\displacement/4),%edi
    movl (%ebp,%edi,4),%eax
#elif KIND == 5
    // U load writes its own address register, then the next writer changes it.
    leal \\displacement(%ebp),%edi
    movl (%edi),%edi
#else
    leal \\displacement(%ebp),%edi
#if KIND == 0
    movl (%edi),%eax
#elif KIND == 1
    movb (%edi),%al
#elif KIND == 2
    addl (%edi),%eax
#elif KIND == 3
    xorl (%edi),%eax
#else
#error unsupported KIND
#endif
#endif
    .endr
''')
    text=once(text,'    movl $0,\\displacement(%ebp)',
              '    movl $(1+\\displacement/64),\\displacement(%ebp)')
    text=once(text,'    testl %eax,%eax\n    jne fail','''#if KIND == 2
    cmpl $640,%eax
#elif KIND == 3 || KIND == 5 || KIND == 7
    cmpl $0,%eax
#else
    cmpl $4,%eax
#endif
    jne fail
#if KIND == 5
    cmpl $4,%edi
    jne fail
#endif''')
    text=once(text,'    cmpl $0x3f800000,\\displacement(%ebp)',
              '    cmpl $0,\\displacement(%ebp)')
    return text


if __name__=='__main__':
    import argparse
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    with args.out.open('x') as f:f.write(transform((HERE/'ref-operand-prime.S').read_text()))
