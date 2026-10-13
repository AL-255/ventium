"""Recheck FRNDINT source closure, native/exact results and closed ownership."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import prepare
import vectors

def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--leaf',type=Path,required=True)
    ap.add_argument('--unit',required=True)
    a=ap.parse_args();root=a.leaf.resolve(strict=True)
    assert __debug__ and os.sched_getaffinity(0)=={12}
    assert root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    started=json.loads((root/'started.json').read_text());closed=json.loads((root/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert not closed['whole_core'] and not closed['canonical_gate_passed']
    assert len(started['definitions'])==152
    assert all(sha(p)==h for p,h in started['pins'].items())
    owner=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',a.unit,
        '-p','MainPID','-p','ExecMainStatus','-p','InvocationID',
        '-p','ExecMainStartTimestampMonotonic','-p','ExecMainExitTimestampMonotonic'],text=True).splitlines())
    assert owner['MainPID']=='0' and owner['ExecMainStatus']=='0'
    # The guarded scope has its own invocation; do not conflate it with the
    # containing service. Bind its terminal journal interval to that owner.
    events=[json.loads(line) for line in subprocess.check_output(['journalctl','--user',
        '--no-pager','-o','json','USER_INVOCATION_ID='+started['invocation']],text=True).splitlines()]
    starts=[e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and e.get('JOB_TYPE')=='start']
    stops=[e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and 'MEMORY_PEAK' in e]
    assert len(starts)==len(stops)==1 and starts[0]['JOB_RESULT']=='done'
    assert str(root.parent.name) in starts[0]['MESSAGE'] and root.name in starts[0]['MESSAGE']
    assert int(owner['ExecMainStartTimestampMonotonic'])<=int(starts[0]['__MONOTONIC_TIMESTAMP'])<int(stops[0]['__MONOTONIC_TIMESTAMP'])<=int(owner['ExecMainExitTimestampMonotonic'])
    owner.update(scope_invocation=started['invocation'],scope_memory_peak=stops[0]['MEMORY_PEAK'],
                 scope_swap_peak=stops[0].get('MEMORY_SWAP_PEAK'))
    rows=vectors.rows();assert rows==json.loads((root/'cases.json').read_text())
    assert b''.join(map(vectors.pack,rows))==(root/'stdin.bin').read_bytes()
    native=subprocess.run([root/'native'],input=(root/'stdin.bin').read_bytes(),capture_output=True,timeout=30)
    assert native.returncode==0 and not native.stderr and native.stdout==(root/'native.bin').read_bytes()
    import struct
    expected=list(struct.iter_unpack('<4I',native.stdout)); assert len(expected)==len(rows)
    exact_checks=0
    for r,v in zip(rows,expected):
        exact=vectors.finite_result(r)
        if exact is not None:
            assert (v[0]|v[1]<<32|v[2]<<64,v[3]&0x82ff)==exact
            exact_checks+=1
    source=Path(started['parent'])/'candidate'
    names=sorted(str(p.relative_to(source)) for p in source.rglob('*') if p.is_file()); assert len(names)==195
    output={}; artifacts={}; witness={}
    for row in closed['rows']:
        mode=row['name']; variant=root/mode
        assert row['build_exit']==row['native_exit']==0 and [12] in row['affinities']
        assert all(sha(p)==h for p,h in row['artifacts'].items())
        for n in names:
            actual=(variant/'source'/n).read_bytes()
            wanted=prepare.transform((source/n).read_text(),n).encode() if mode=='repaired' and n in prepare.PARENTS else (source/n).read_bytes()
            assert actual==wanted,n
        for archive in row['pch_archives']:
            assert sha(archive['archive'])==archive['archive_sha256']
            with gzip.open(archive['archive'],'rb') as f:
                assert hashlib.file_digest(f,'sha256').hexdigest()==archive['sha256']
        log=(variant/'run.log').read_text()
        found=re.findall(r'^ROW (\d+) ([0-9a-f]+) ([0-9a-f]+) ([0-9a-f]+) (\d+) (\d+)$',log,re.M)
        assert len(found)==len(rows) and 'FRND-TRANSPORT-OK rows=28684 resets=2' in log
        actual=[(int(n),int(value,16),int(sw,16),int(tag,16),int(lat),int(stack))
                for n,value,sw,tag,lat,stack in found]
        diff=[]; numeric=[]; c1=[]; exception=[]
        for i,(r,v,new) in enumerate(zip(rows,expected,actual)):
            assert new[0]==i
            if r['kind']:continue
            value=v[0]|v[1]<<32|v[2]<<64
            if new[1]!=value:numeric.append(i)
            if (new[2]^v[3])&0x200:c1.append(i)
            if (new[2]^v[3])&0x80ff:exception.append(i)
            if new[1]!=value or (new[2]^v[3])&0x82ff:diff.append(i)
            if mode=='repaired':
                assert new[3]==int(bool(r['tag']) and not(r['cw']&1))
                assert new[5]==int(bool(r['tag']))
            if mode=='parent' and new[1]!=value:
                key=('positive_2p63' if r['hi']==0x403d and r['m']==(1<<64)-1
                     else 'precision24' if (r['cw']&0x300)==0 and 0x4017<=r['hi']<0x403d
                     else 'other')
                if key not in witness:witness[key]=dict(case=r,parent=new,expected_value=f'{value:020x}',expected_fsw=f'{v[3]:04x}')
        assert diff==row['mismatch_indices']
        output[mode]=dict(mismatches=len(diff),numeric=len(numeric),c1=len(c1),exception=len(exception))
        if mode=='parent':baseline=actual
        else:
            assert not diff
            assert all(old[4:]==new[4:] for old,new in zip(baseline,actual))
            assert all(old==new for old,new,r in zip(baseline,actual,rows) if r['kind'])
        artifacts.update(row['artifacts'])
    assert {'positive_2p63','precision24'}<=set(witness)
    for p in (root/'started.json',root/'closed.json',root/'native',root/'native.bin',
              root/'cases.json',root/'stdin.bin',root/'vectors.txt',Path(__file__)):
        artifacts[str(p)]=sha(p)
    result=dict(passed=True,owner=owner,pins_checked=len(started['pins']),source_files=195,
        cases=len(rows),frndint_cases=sum(r['kind']==0 for r in rows),control_cases=72,
        integer_oracle_checks=exact_checks,results=output,witness=witness,artifacts=artifacts,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (root/'audit.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('artifacts','witness')},indent=2))


if __name__=='__main__':main()
