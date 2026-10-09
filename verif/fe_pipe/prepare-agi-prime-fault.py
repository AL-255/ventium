#!/usr/bin/env python3
"""Precise first/split-page faults for a prior-writer -> fast load sequence."""
import importlib.util
from pathlib import Path

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('integer_fault',HERE/'prepare-ref-prime-int-fault.py')
integer=importlib.util.module_from_spec(spec);spec.loader.exec_module(integer)
CHANGES={
    'source_op:\n':'    movl %ebx,%edx\nsource_op:\n',
    '    movsbl (%ebx),%esi':'    movb (%edx),%al\n    movzbl %al,%esi',
    '    movswl (%ebx),%esi':'    movl (%edx),%esi',
    '    imull (%ebx),%esi':'    addl (%edx),%esi',
    '    cmpl $12,%esi':'    cmpl $7,%esi',
}


def transform(text):
    text=integer.transform(text)
    # P5 has no SIL byte register. Use ESI for the checked architectural result
    # through an ordinary AL load followed by MOVZX register, after source_op.
    for old,new in CHANGES.items():
        if text.count(old)!=1:raise ValueError('missing/ambiguous fixture anchor: '+old)
        text=text.replace(old,new)
    return text


if __name__=='__main__':
    import argparse
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    with args.out.open('x') as f:f.write(transform(args.source.read_text()))
