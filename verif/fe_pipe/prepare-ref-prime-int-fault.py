#!/usr/bin/env python3
"""MOVSX/IMUL absent-page and split-page restart with an older FP divide."""
import argparse
import importlib.util
from pathlib import Path

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('scalar_fault',HERE/'prepare-fp-scalar-load-fault.py')
scalar=importlib.util.module_from_spec(spec);spec.loader.exec_module(scalar)
CHANGES={
    '''#if KIND == 2
#define SOURCE 0x400ffc
#else
#define SOURCE 0x400ffe
#endif''': '''#if KIND == 0
#define SOURCE 0x401000
#elif KIND == 1
#define SOURCE 0x400fff
#else
#define SOURCE 0x400ffe
#endif''',
    '''#if KIND == 0
#define LO 4
#define HI 0
#elif KIND == 1
#define LO 0x40800000
#define HI 0
#else
#define LO 0
#define HI 0x40100000
#endif''': '#define LO 4\n#define HI 0',
    '''#if KIND == 2
    movl $LO,0x14ffc
    movl $HI,0x15000
#else
    movl $LO,0x14ffe
#endif''': '''#if KIND == 0
    movl $LO,0x15000
#elif KIND == 1
    movl $LO,0x14fff
#else
    movl $LO,0x14ffe
#endif''',
    'do_op:\n    flds 0x3060':'do_op:\n    movl $3,%esi\n    flds 0x3060',
    '''#if KIND == 0
    fiaddl (%ebx)
#elif KIND == 1
    fcoms (%ebx)
#else
    fcoml (%ebx)
#endif''': '''#if KIND == 0
    movsbl (%ebx),%esi
#elif KIND == 1
    movswl (%ebx),%esi
#else
    imull (%ebx),%esi
#endif''',
    'integer_begin:\n    incl %edi': '''integer_begin:
#if KIND == 2
    cmpl $12,%esi
#else
    cmpl $4,%esi
#endif
    jne fail
    incl %edi''',
    '    cmpl $source_op,0x304c':'    cmpl $older_op,0x304c',
    '    cmpl %ebx,0x3054':'    cmpl $0x3064,0x3054',
    '''#if KIND == 0
    cmpl $0x40180000,0x3024
#else
    cmpl $0x40000000,0x3024
#endif''':'    cmpl $0x40000000,0x3024',
    '''    fnstsw %ax
    andl $0x3800,%eax
    cmpl $0x3000,%eax''': '''    // Inspect SW from the environment already captured above. The pinned
    // QEMU register-form FNSTSW mistakenly updates FIP; no second FP probe is
    // needed to check the interrupted TOP, and integer retry must preserve FIP.
    movzwl 0x3044,%eax
    andl $0x3800,%eax
    cmpl $0x3000,%eax''',
    '''    fstl 0x3030
    fwait
    cmpl $0,0x3030
    jne fail
    cmpl $0x40000000,0x3034
    jne fail''': '''    // Do not change the interrupted FIP/FDP in this integer-fault handler.
    // The pinned QEMU FLDENV helper restores only CW/SW/tags, not pointers.
    // The unchanged post-retry FSTPL checks the divide's exact value, and the
    // complete QEMU trace also checks ST0 throughout fault delivery/retry.''',
}


def transform(text):
    text=scalar.transform(text)
    for old,new in CHANGES.items():
        if text.count(old)!=1:raise ValueError('missing/ambiguous fixture anchor: '+old)
        text=text.replace(old,new)
    return text


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    result=transform(args.source.read_text())
    with args.out.open('x') as f:f.write(result)
