"""Broaden cold strict-#MF delivery on existing parent/candidate UV-fast models.

Use real arithmetic to arm a delayed exception, never force CPU state. Each
waiting instruction must fault at its own EIP before retry. Neutralizing
instructions run only after retry, preserving the existing complete guest
checks for scaled ST0, ST1, TOP, #NM priority and exactly-once FLD1. This does
not promote the private QEMU or waive the failed canonical gate.
"""
import inspect
from pathlib import Path

import run_underflow_delivery as base

TEMPLATE_SHA='864610cee0afefd8dcf5b051bb9da77daf834aa824d83df26035addb70ca7905'
MODELS={
    'control':('branch-address-core-r1','6deb3e92ae302d2166c18d239711754c049f1f775f2518a2f5b576108eb8b16d'),
    'parent':('raw-prime-storage-core-r1','41f99bcff8125a2caa7fe768f03f242bed1a43323e4d3a190109167248a34e9b'),
    'candidate':('system-read-ack-core-r1','005d0f17a3360588d6b67c5f49267db785cb7cc07893ee6a14dc42cafe615aeb'),
}
# Zero/one memory operands and scratch are initialized before the arithmetic
# producer, not between it and the waiting instruction. The second and later
# instructions below undo only ordinary stack/sign effects after successful
# fault/retry; delivering #MF there instead fails the saved-EIP assertion.
WAITERS={
    'fwait':'fwait', 'fnop':'fnop', 'fld1':'fld1',
    'fchs':'fchs\n    fchs', 'fabs':'fabs',
    'fxch':'fxch %st(1)\n    fxch %st(1)',
    'ffree':'ffree %st(7)',
    'fincstp':'fincstp\n    fdecstp', 'fdecstp':'fdecstp\n    fincstp',
    'fld32':'flds 0x20c0\n    fstp %st(0)',
    'fld64':'fldl 0x20c0\n    fstp %st(0)',
    'fld80':'fldt 0x20c0\n    fstp %st(0)',
    'fild16':'filds 0x20c0\n    fstp %st(0)',
    'fild32':'fildl 0x20c0\n    fstp %st(0)',
    'fild64':'fildq 0x20c0\n    fstp %st(0)',
    'fst32':'fsts 0x2100', 'fst64':'fstl 0x2100',
    'fstp80':'fstpt 0x2100\n    fldt 0x2100',
    'fstreg':'fst %st(0)', 'fist16':'fists 0x2100', 'fist32':'fistl 0x2100',
    'fadd32':'fadds 0x20c0', 'fsub32':'fsubs 0x20c0',
    'fmul32':'fmuls 0x20d0', 'fdiv32':'fdivs 0x20d0',
    'fcom':'fcom %st(0)', 'fucom':'fucom %st(1)', 'ftst':'ftst',
    'fldcw':'fldcw CWCELL',
}


def vectors():
    rows=[r for r in base.vectors() if r['name'].startswith('normal')]
    assert len(rows)==2 and {r['op'] for r in rows}=={0,1}
    return rows


def source(row,waiter):
    assert waiter in WAITERS
    if waiter=='fld1':
        text=base.source(row,'fld1')
    else:
        text=base.source(row,'fnop')
        body=WAITERS[waiter]
        if waiter=='fabs' and row['values'][0][0]&0x8000:body+='\n    fchs'
        assert text.count('    fnop\n')==2
        text=text.replace('    fnop\n','    '+body+'\n')
    anchor='.macro ARM_PENDING_MF\n    fninit\n'
    assert text.count(anchor)==1
    text=text.replace(anchor,anchor+
        '    movl $0, 0x20c0\n    movl $0, 0x20c4\n    movl $0, 0x20c8\n'
        '    movl $0x3f800000, 0x20d0\n')
    return text


def derive():
    assert base.sha(base.__file__)==TEMPLATE_SHA
    text=inspect.getsource(base.main)
    replacements=[
        ("(BASE, LINK, Path(__file__), Path(tracefmt.__file__),",
         "(BASE, LINK, Path(__file__), Path(BASE_RUNNER), Path(tracefmt.__file__),"),
        ("('fwait', 'fnop', 'fld1')","tuple(WAITERS)"),
        ("if r['model'] == 'branch'","if r['model'] in ('parent','candidate')"),
        ('len(rows) == 216','len(rows) == 2*len(WAITERS)*3*3'),
        ("'--system', '--cosim', '--cycle-func', '--l1-axi',",
         "'--system', '--cosim', '--cycle-func', '--l1-axi', '--x87',"),
    ]
    for old,new in replacements:
        assert text.count(old)==(2 if old=="('fwait', 'fnop', 'fld1')" else 1),old
        text=text.replace(old,new)
    # Require the old nonstrict model to demonstrate the policy gap while
    # retaining its actual failing exits. It is never an acceptance substitute.
    marker='    stable = all(sha(p) == h for p, h in pins.items())\n'
    assert text.count(marker)==1
    text=text.replace(marker,
        "    controls=[r for r in rows if r['model']=='control']\n"
        "    if len(controls)!=2*len(WAITERS)*3 or any(\n"
        "        r['passed']!=(r['waiter'] in ('fwait','fnop')) for r in controls):\n"
        "        errors.append(dict(error='nonstrict negative-control inventory changed'))\n"+marker)
    marker="        definitions[label] = started['definitions']\n"
    assert text.count(marker)==1
    text=text.replace(marker,marker+
        "        assert ('VEN_X87_MF_STRICT' in definitions[label])==(label!='control')\n")
    compile(text,__file__,'exec')
    return text


def main():
    scope=dict(base.__dict__,__file__=__file__,BASE_RUNNER=base.__file__,MODELS=MODELS,
               WAITERS=WAITERS,vectors=vectors,source=source)
    exec(compile(derive(),__file__,'exec'),scope)
    return scope['main']()


if __name__=='__main__':raise SystemExit(main())
