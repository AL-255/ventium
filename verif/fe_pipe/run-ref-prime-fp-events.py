#!/usr/bin/env python3
"""Reuse the exact scalar fault/debug corpus on a resident-prime A/B pair.

Only profile admission and unchanged command-count expectations differ: BOTH
models already contain scalar-load-command. Complete QEMU comparisons, guest
frame/pointer checks, delivered-fault counts and native bounds are unchanged.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

HERE=Path(__file__).resolve().parent


def once(text,old,new):
    if text.count(old)!=1:raise ValueError('missing/ambiguous driver anchor: '+old)
    return text.replace(old,new)


def transform(text,fault,integer=False):
    if 'VEN_REF_OPERAND_PRIME' in text:raise ValueError('already transformed')
    text=once(text,"else 'VEN_FP_SCALAR_LOAD_CMD'","else 'VEN_REF_OPERAND_PRIME'")
    # The selected existing branch still generates the three scalar fixtures.
    # Keep the legacy/default branch untouched, but name this run accurately.
    assert "'scalar-load-cmd'" in text
    text=text.replace("'scalar-load-cmd'","'ref-operand-prime'")
    anchor="    save(args.out/'inputs.json', pins)" if fault else "    save(args.out / 'inputs.json', pins)"
    text=once(text,anchor,
              "    pins[str(Path(__file__).with_name('run-ref-prime-fp-events.py'))] = "
              "sha(Path(__file__).with_name('run-ref-prime-fp-events.py'))\n"+anchor)
    if fault:
        text=once(text,"(9 if row['model'] == 'candidate' else 0)",'0' if integer else '9')
        if integer:
            text=once(text,"prepare-fp-scalar-load-fault.py'","prepare-ref-prime-int-fault.py'")
            text=once(text,anchor,"    pins[str(REPO/'verif/fe_pipe/prepare-fp-scalar-load-fault.py')] = sha(REPO/'verif/fe_pipe/prepare-fp-scalar-load-fault.py')\n"+anchor)
    else:
        text=once(text,"        assert all(r[witness]==0 for r in result['measurements'] if r['model']=='control')",
                  "        assert all(r[witness]==12 for r in result['measurements']), 'same six ordinary/retry commands per trace mode'")
    return text


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('control','candidate','out'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--fault',action='store_true')
    parser.add_argument('--integer',action='store_true',help='MOVSX/IMUL fault/retry corpus')
    args=parser.parse_args()
    assert not args.integer or args.fault
    source=HERE/('run-fp-mem64-queue.py' if args.fault else 'run-fp-scalar-events.py')
    original=source.read_bytes();digest=hashlib.sha256(original).hexdigest()
    transformed=transform(original.decode(),args.fault,args.integer)
    # Sidecar records exactly which unchanged oracle runner was composed.
    sidecar=args.out.with_name(args.out.name+'-driver.json')
    with sidecar.open('x') as f:json.dump(dict(source=str(source),sha256=digest,
        transformed_sha256=hashlib.sha256(transformed.encode()).hexdigest(),
        feature='VEN_REF_OPERAND_PRIME',standard_suite=False,gameplay_ipc=None),f,indent=2)
    sys.argv=[str(source),'--control',str(args.control),'--candidate',str(args.candidate),
              '--out',str(args.out),'--feature','ref-operand-prime',*(['--fault'] if args.fault else [])]
    try:exec(compile(transformed,str(source),'exec'),{'__file__':str(source),'__name__':'__main__'})
    finally:assert hashlib.sha256(source.read_bytes()).hexdigest()==digest


if __name__=='__main__':main()
