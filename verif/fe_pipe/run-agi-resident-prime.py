#!/usr/bin/env python3
"""AGI A/B microgate, retaining complete QEMU and real U/V comparisons.

Compose the existing pinned boundary runner; keep all native exit, complete
trace, exact work, and nonregression checks. Every transformed anchor is unique.
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


def transform(text):
    text=once(text,"    assert profiles['candidate']==profiles['control']|{'VEN_REF_OPERAND_PRIME'}",
              "    assert profiles['candidate']==profiles['control']|{'VEN_RAW_AGI_PRIME'}")
    text=once(text,"    assert 'VEN_REF_OPERAND_PRIME' not in profiles['control']",
              "    assert 'VEN_RAW_AGI_PRIME' not in profiles['control']\n"
              "    assert 'VEN_REF_OPERAND_PRIME' in profiles['control']")
    text=once(text,"    source=HERE/'ref-operand-prime.S'",'''    import importlib.util
    fixture_path=HERE/'prepare-agi-prime-fixture.py'
    spec=importlib.util.spec_from_file_location('agi_fixture',fixture_path)
    fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
    source=args.out/'agi-resident-prime.S'
    with source.open('x') as f:f.write(fixture.transform((HERE/'ref-operand-prime.S').read_text()))
    for p in (fixture_path,HERE/'ref-operand-prime.S',HERE/'run-agi-resident-prime.py'):
        pins[str(p)]=sha(p)''')
    text=once(text,r'\[FETCHDBG:REFPRIME\]',r'\[FETCHDBG:AGIPRIME\]')
    text=once(text,"                if case[0]>=7:","                if case[0]>=6:")
    text=once(text,"            clocks=int(footer[0][1])",'''            clocks=int(footer[0][1])
            agi_counts=re.findall(r'\\[11\\]\\s+(\\d+)\\s+[0-9.]+%\\s+pipe_agi',text)
            # core.sv deliberately omits zero-valued bucket rows. Require the
            # complete profile section, but a missing AGI row means zero.
            assert text.count('-- S_PIPE clocks by FIRST bail arm (priority order) --')==1
            assert len(agi_counts)<=1, 'duplicate paid AGI counter'
            paid_agi=int(agi_counts[0]) if agi_counts else 0''')
    text=once(text,"    print(json.dumps({k:v for k,v in result.items() if k not in ('measurements','gains')},indent=2))",
              "    print(json.dumps(dict(passed=result['passed'],errors=len(result['errors']),"
              "measurements=len(result['measurements']),inputs_unchanged=result['inputs_unchanged'],"
              "gameplay_ipc=None,standard_suite=False),indent=2))")
    text=once(text,'total_clocks=clocks,warm_cycles=warm,resident_primes=primes,full_qemu_diff=True)',
              'total_clocks=clocks,warm_cycles=warm,resident_primes=primes,paid_agi=paid_agi,full_qemu_diff=True)')
    text=once(text,"                gains.append(dict(case=case,latency=latency,control=sum(a['warm_cycles']),",'''                if case[0] in (0,2,3,4,5) and case[3]>28:
                    assert b['resident_primes']==0, ('split-line prime',case)
                assert b['paid_agi']>=b['resident_primes']//2, 'hint without a paid AGI'
                gains.append(dict(case=case,latency=latency,control=sum(a['warm_cycles']),''')
    # The new loop contains twice as many instructions as the older operand
    # fixture. Bound still exceeds its entire fixed 64-round workload.
    assert text.count("'2000'")==2
    text=text.replace("'2000'","'4000'")
    text=once(text,'len(gold.records)<2000','len(gold.records)<4000')
    return text


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('control','candidate','out'):ap.add_argument('--'+name,type=Path,required=True)
    ap.add_argument('--smoke',action='store_true')
    args=ap.parse_args()
    source=HERE/'run-ref-operand-prime.py'
    original=source.read_bytes();digest=hashlib.sha256(original).hexdigest()
    text=transform(original.decode())
    with args.out.with_name(args.out.name+'-driver.json').open('x') as f:
        json.dump(dict(source=str(source),sha256=digest,
            transformed_sha256=hashlib.sha256(text.encode()).hexdigest(),
            feature='VEN_RAW_AGI_PRIME',standard_suite=False,gameplay_ipc=None),f,indent=2)
    sys.argv=[str(source),'--control',str(args.control),'--candidate',str(args.candidate),
              '--out',str(args.out),*(['--smoke'] if args.smoke else [])]
    try:exec(compile(text,str(source),'exec'),{'__file__':str(source),'__name__':'__main__'})
    finally:assert hashlib.sha256(source.read_bytes()).hexdigest()==digest


if __name__=='__main__':main()
