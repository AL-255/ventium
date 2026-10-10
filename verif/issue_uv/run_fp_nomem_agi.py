#!/usr/bin/env python3
"""Regression witness: x87 timing cuts must retain integer AGI resident priming.

Runs the existing complete-state/cycle FP corpus engine on a focused address
dependency loop. The formerly regressing whole-core model is a required
negative control, not accepted as a slower alternate implementation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from run_fp_nomem_system import OLD, NEW

HERE=Path(__file__).resolve().parent


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for flag in ('control','candidate','rejected','out'):
        ap.add_argument('--'+flag,type=Path,required=True)
    args=ap.parse_args()
    root=args.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and Path(os.environ['TMPDIR']).resolve()==scratch
    root.mkdir()
    source=HERE/'fp-payload-system.S'; original=source.read_text()
    begin=original.index('hot_u:\nhot_load:\n'); end=original.index('    incl %ebp\n',begin)
    selected=original[:begin]+'''hot_u:
    movl $0x3000,%eax
hot_load:
    movl (%eax),%edx
'''+original[end:]
    fixture=root/'agi-shared-live-permit.S'
    with fixture.open('x') as f:f.write(selected)
    driver=HERE/'run-fp-payload-ab.py'; text=driver.read_text()
    assert text.count(OLD)==1
    adapted=text.replace(OLD,NEW).replace('HERE = Path(__file__).resolve().parent','HERE = Path('+repr(str(HERE))+')')
    exact="source = HERE/'fp-payload-system.S'"
    assert adapted.count(exact)==1
    adapted=adapted.replace(exact,'source = Path('+repr(str(fixture))+')')
    exact="'+ven_faultlog', '+ven_fpdirectlog']"
    assert adapted.count(exact)==1
    adapted=adapted.replace(exact,"'+ven_faultlog', '+ven_fpdirectlog', '+ven_fetchdbg']")
    runner=root/'run_agi_same_profile.py'
    with runner.open('x') as f:f.write(adapted)
    models={k:getattr(args,k).resolve(strict=True) for k in ('control','candidate','rejected')}
    pins={str(p):sha(p) for p in (Path(__file__),HERE/'run_fp_nomem_system.py',source,fixture,driver,runner,*models.values())}
    def save(name,value):
        with (root/name).open('x') as f:json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,models={k:str(v) for k,v in models.items()},invocation=os.environ.get('INVOCATION_ID')))
    results=[]
    for label in ('candidate','rejected'):
        command=['python3','-B',str(runner),'--control',str(models['control']),
            '--candidate',str(models[label]),'--out',str(root/label),'--kind','0','--workers','32']
        for offset in (0,1,7,15,30,31):command+=['--offset',str(offset)]
        save(label+'.command.json',command)
        with (root/(label+'.log')).open('x') as f:
            p=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=180)
        closed=json.loads((root/label/'closed.json').read_text())
        assert closed['pins_unchanged'] and closed['all_children_reaped']
        control_marks=[]; tested_marks=[]
        for name,output in (('control',control_marks),('candidate',tested_marks)):
            for log in (root/label).glob(f'*/{name}-lat*-cycle.stdout'):
                output.extend(re.findall(r'^\[FETCHDBG:AGIPRIME\] .+$',log.read_text(),re.M))
        assert control_marks, 'the positive control did not exercise AGI resident priming'
        if label=='candidate':
            assert p.returncode==0 and closed['passed'] and not closed['errors']
            assert tested_marks and len(tested_marks)==len(control_marks)
            assert len(closed['deltas'])==24 and all(r['saved_clocks']==0 for r in closed['deltas'])
        else:
            assert p.returncode!=0 and not closed['passed'] and closed['errors']
            assert all('entire cycle record lists differ' in e.get('error','') for e in closed['errors'] if 'case' in e)
            assert not tested_marks, 'the negative did not reproduce suppressed AGI priming'
        results.append(dict(model=label,native_exit=p.returncode,control_agi_accepts=len(control_marks),
            tested_agi_accepts=len(tested_marks),expected_negative=label=='rejected'))
    stable=all(sha(Path(p))==h for p,h in pins.items())
    assert stable
    save('closed.json',dict(passed=True,pins_unchanged=stable,rows=results,
        standard_suite=False,gameplay_ipc=None,performance_policy_changed=False))
    print(json.dumps(results),flush=True)


if __name__=='__main__':main()
