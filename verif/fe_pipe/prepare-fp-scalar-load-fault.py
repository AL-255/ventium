#!/usr/bin/env python3
"""Derive precise FIAR32/FCOM32/FCOM64 operand-page-fault fixtures.

Keep the older divide, real page-table repair, exact saved pointer/frame and
full guest-state assertions. Only source type, width and expected result vary.
"""
import argparse
from pathlib import Path

CHANGES = {
    '#define SOURCE 0x400ffc': '''#if KIND == 2
#define SOURCE 0x400ffc
#else
#define SOURCE 0x400ffe
#endif''',
    '''#if KIND == 2
#define LO -7
#define HI -1
#else
#define LO 0
#define HI 0x40100000
#endif''': '''#if KIND == 0
#define LO 4
#define HI 0
#elif KIND == 1
#define LO 0x40800000
#define HI 0
#else
#define LO 0
#define HI 0x40100000
#endif''',
    '''    movl $LO,0x14ffc
    movl $HI,0x15000''': '''#if KIND == 2
    movl $LO,0x14ffc
    movl $HI,0x15000
#else
    movl $LO,0x14ffe
#endif''',
    '''#if KIND == 0
    faddl (%ebx)
#elif KIND == 1
    fldl (%ebx)
#else
    fildq (%ebx)
#endif''': '''#if KIND == 0
    fiaddl (%ebx)
#elif KIND == 1
    fcoms (%ebx)
#else
    fcoml (%ebx)
#endif''',
    '''#elif KIND == 1
    cmpl $0x40100000,0x3024
#else
    cmpl $0xc01c0000,0x3024''': '''#else
    cmpl $0x40000000,0x3024''',
    '''#if KIND != 0
    fstp %st(0)
#endif
    fstp %st(0)''': '    fstp %st(0)',
}


def transform(text):
    for old,new in CHANGES.items():
        if text.count(old) != 1:
            raise ValueError('missing or ambiguous fixture anchor: '+old)
        text=text.replace(old,new)
    return text


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args=parser.parse_args()
    result=transform(args.source.read_text())
    with args.out.open('x') as f:f.write(result)
