#!/usr/bin/env python3
"""Inventory retained canonical failures without changing traces or comparators."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sys

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'diff'))
import tracefmt


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','candidate','out'):
        ap.add_argument('--'+name,type=Path,required=True)
    args=ap.parse_args()
    parent=args.parent.resolve(strict=True); candidate=args.candidate.resolve(strict=True)
    out=args.out.resolve()
    assert __debug__ and out.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    assert not out.exists()
    pins={str(Path(__file__).resolve()):sha(Path(__file__).resolve())}
    for root in (parent,candidate):
        started=json.loads((root/'verify-started.json').read_text())
        done=json.loads((root/'verify-closed.json').read_text())
        assert done['pins_unchanged'] and done['canonical_gate_native_exit']==2
        assert not done['canonical_gate_passed'] and not done['masks_or_goldens_or_bands_changed']
        pins.update(started['pins'])
        for p in (root/'verify-started.json',root/'verify-closed.json'):
            pins[str(p)]=sha(p)
    results=sorted((candidate/'generic-work').glob('*.func.result'))
    assert len(results)==108
    failures=[]; totals=Counter(); records=0; length_reports=0; identical=0
    stream_differences=[]
    pattern=r'n=(\d+) pc=(0x[0-9a-f]+) field=(\w+): expected\(A\)=(0x[0-9a-f]+) got\(C\)=(0x[0-9a-f]+)'
    for result in results:
        before=parent/'generic-work'/result.name
        fields=result.read_text().strip().split('|')
        assert len(fields)==6 and fields[0]=='FUNC'
        assert fields[:5]==before.read_text().strip().split('|')[:5]
        totals[fields[3]]+=1
        stem=fields[1]
        old=parent/'generic-work'/(stem+'.func_rtl.vtrace')
        new=candidate/'generic-work'/old.name
        a,b=tracefmt.read_trace(str(old)),tracefmt.read_trace(str(new))
        assert (a.mode,a.x87,a.sys)==(b.mode,b.x87,b.sys)
        # The two canonical invocations obtain independent QEMU initial states.
        # In particular, the stack address can differ. Report complete equality
        # honestly; never mask ESP or call this an identical-input A/B proof.
        identical+=a.records==b.records
        if a.records!=b.records:
            first=next((i for i,(x,y) in enumerate(zip(a.records,b.records)) if x!=y),None)
            stream_differences.append(dict(program=stem,parent_records=len(a.records),
                candidate_records=len(b.records),first_different_record=first,
                parent_first=a.records[first] if first is not None else None,
                candidate_first=b.records[first] if first is not None else None))
        records+=len(b.records)
        log=result.with_name(stem+'.func_cmp.txt')
        comparison=log.read_text()
        length='LENGTH MISMATCH:' in comparison
        length_reports+=length
        match=re.search(pattern,comparison)
        if fields[3]=='FAIL':
            row=dict(program=stem,class_name=fields[2],length_mismatch=length,summary=fields[4])
            if match:
                n,pc,field,expected,got=match.groups()
                row.update(first_n=int(n),first_pc=pc,first_field=field,
                           expected=expected,got=got,xor=int(expected,0)^int(got,0))
            else:
                assert length and 'length mismatch only' in comparison.lower()
            failures.append(row)
        else:
            assert fields[3]=='PASS' and not length and not match
        for p in (result,before,old,new,log):
            pins[str(p)]=sha(p)
    assert all(sha(Path(p))==h for p,h in pins.items())
    report=dict(audit_complete=True,canonical_gate_passed=False,
        functional_totals=dict(totals),complete_rtl_streams_compared=len(results),
        complete_rtl_streams_identical=identical,stream_differences=stream_differences,
        complete_rtl_records=records,length_mismatch_reports=length_reports,
        length_only_failures=sum('first_field' not in r for r in failures),
        field_mismatch_failures=sum('first_field' in r for r in failures),
        failures=failures,pins=pins,gameplay_ipc=None,standard_suite=False)
    with out.open('x') as f:json.dump(report,f,indent=2)
    print(json.dumps({k:v for k,v in report.items() if k not in ('pins','failures','stream_differences')},indent=2))


if __name__=='__main__':main()
