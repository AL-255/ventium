#!/usr/bin/env python3
"""Reuse TF/RF/TS/EM cold-event checks for read-only scalar final handoff."""
import argparse
from pathlib import Path

CHANGES = {
    '    movl $0xdeadbeef,0x2100': '    movl $0,0x2100\n    movl $0,0x2104',
    '    fistl 0x2100': '''#if KIND == 0
    fiaddl 0x2100
#elif KIND == 1
    fcoms 0x2100
#else
    fcoml 0x2100
#endif''',
    '    cmpl $0xdeadbeef,0x2100': '    cmpl $0,0x2100',
    '    cmpl $1,0x2000\n    jne fail\n    movb $0x42,%al': '''    cmpl $1,0x2000
    jne fail
    fistl 0x2110
    fwait
    cmpl $1,0x2110
    jne fail
    movb $0x42,%al''',
}


def transform(text):
    if text.count('    cmpl $1,0x2100') != 2:
        raise ValueError('missing/ambiguous post-instruction and #DB data guards')
    text=text.replace('    cmpl $1,0x2100','    cmpl $0,0x2100')
    for old,new in CHANGES.items():
        if text.count(old) != 1:raise ValueError('missing/ambiguous event fixture anchor: '+old)
        text=text.replace(old,new)
    return text


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    output=transform(args.source.read_text())
    with args.out.open('x') as f:f.write(output)
