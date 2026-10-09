#!/usr/bin/env python3
"""TF/RF and TS/EM visits to an ordinary address writer followed by a load."""
import argparse
from pathlib import Path

CHANGES={
    '    orl $1,%eax':'''    orl $1,%eax
#if !POP_KIND
    // Positive cases use ordinary cached RAM; POP_KIND=1 retains reset CD/NW
    // as an explicit negative control. Neither case changes an access result.
    andl $0x9fffffff,%eax
#endif''',
    '    movl $0xdeadbeef,0x2100':'    movl $0x12345678,0x2100',
    '    pushl $hot_op\n    iretl':'    pushl $hot_op\n    movl $0,%eax\n    iretl',
    '    fistl 0x2100':'''    movl $0x2100,%ebx
    .global hot_load
hot_load:
#if KIND == 0
    movb (%ebx),%al
#elif KIND == 1
    movl (%ebx),%eax
#else
    addl (%ebx),%eax
#endif''',
    'hot_after:\n    cmpl $1,0x2100':'''hot_after:
#if KIND == 0
    andl $0xff,%eax
    cmpl $0x78,%eax
#else
    cmpl $0x12345678,%eax
#endif''',
    '    cmpl $2,0x2004':'    cmpl $0,0x2004',
    'db_handler:\n    cmpl $1,0x2100':'db_handler:\n    cmpl $0x12345678,0x2100',
    '    cmpl $hot_after,(%esp)':'    cmpl $hot_load,(%esp)',
    '    cmpl $0xdeadbeef,0x2100':'    cmpl $0x12345678,0x2100',
}


def transform(text):
    for old,new in CHANGES.items():
        if text.count(old)!=1:raise ValueError('missing/ambiguous event anchor: '+old)
        text=text.replace(old,new)
    return text


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    with args.out.open('x') as f:f.write(transform(args.source.read_text()))
