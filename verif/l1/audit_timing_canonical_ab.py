#!/usr/bin/env python3
"""Compare every closed canonical A/B record, including already-failing cases.

This does not repair or waive a QEMU failure. It detects a new architectural
regression which could otherwise hide behind an existing red gate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def require_identical(a,b):
    assert (a.mode,a.sys,a.x87)==(b.mode,b.sys,b.x87),'trace profile changed'
    assert len(a.records)==len(b.records),'record count changed'
    for index,(left,right) in enumerate(zip(a.records,b.records)):
        assert left==right,('record changed',index,left,right)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','candidate','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    parent,candidate=args.parent.resolve(strict=True),args.candidate.resolve(strict=True)
    assert __debug__ and args.out.resolve().is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    pins={str(Path(__file__)):sha(Path(__file__))}
    for root in (parent,candidate):
        receipt=root/'verify-closed.json'
        done=json.loads(receipt.read_text())
        assert done['pins_unchanged'] and done['canonical_gate_native_exit'] in (0,2)
        assert not done['masks_or_goldens_or_bands_changed']
        pins[str(receipt)]=sha(receipt)
    result=dict(regression_check_passed=False,errors=[],counts={},canonical_gate_passed=False,
                gameplay_ipc=None,standard_suite=False)
    for kind,expected in (('func',108),('cycle',20)):
        old=sorted((parent/'generic-work').glob('*.'+kind+'_rtl.vtrace'))
        new=sorted((candidate/'generic-work').glob('*.'+kind+'_rtl.vtrace'))
        assert len(old)==len(new)==expected and [p.name for p in old]==[p.name for p in new]
        total=0
        for a,b in zip(old,new):
            for p in (a,b):
                pins[str(p)]=sha(p)
            left,right=tracefmt.read_trace(str(a)),tracefmt.read_trace(str(b))
            try:
                require_identical(left,right)
            except AssertionError as error:
                result['errors'].append(dict(case=b.name,error=repr(error)))
            total+=len(right.records)
        result['counts'][kind]=dict(cases=expected,records=total)
    result['pins_unchanged']=all(sha(Path(p))==h for p,h in pins.items())
    result['regression_check_passed']=not result['errors'] and result['pins_unchanged']
    result['candidate_canonical_gate_passed']=json.loads((candidate/'verify-closed.json').read_text())['canonical_gate_passed']
    with args.out.open('x') as stream:
        json.dump(dict(result,pins=pins),stream,indent=2)
    print(json.dumps(result),flush=True)
    return 0 if result['regression_check_passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
