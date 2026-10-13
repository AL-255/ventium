"""Independently close the decoder-write repair and full fault/retry corpus."""
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import prepare_write_class as recipe

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def load(p):return json.loads(p.read_text())


def owner(unit,inv,code,scope_folder=None):
    p=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
        '-pSubState','-pMainPID','-pExecMainStatus','-pInvocationID'],text=True).splitlines())
    assert p['SubState']==('failed' if code else 'exited') and p['MainPID']=='0' and p['ExecMainStatus']==str(code)
    if scope_folder is None:
        assert p['InvocationID']==inv
    else:
        # A guarded build records its inner scope identity. Join the actual
        # journal lifetime to its terminal service; do not conflate the two.
        lifetime=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
            '-pExecStart','-pExecMainStartTimestampMonotonic','-pExecMainExitTimestampMonotonic'],text=True).splitlines())
        events=[json.loads(s) for s in subprocess.check_output(['journalctl','--user','--no-pager',
            '-o','json','USER_INVOCATION_ID='+inv],text=True).splitlines()]
        events=[e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope']
        launches=[e for e in events if e.get('JOB_TYPE')=='start']
        releases=[e for e in events if 'MEMORY_PEAK' in e]
        assert len(launches)==len(releases)==1
        assert launches[0]['JOB_RESULT']=='done' and scope_folder in launches[0]['MESSAGE']
        assert scope_folder in lifetime['ExecStart']
        lo,hi=[int(lifetime[k]) for k in ('ExecMainStartTimestampMonotonic','ExecMainExitTimestampMonotonic')]
        assert lo<=int(launches[0]['__MONOTONIC_TIMESTAMP'])<int(releases[0]['__MONOTONIC_TIMESTAMP'])<=hi
        p.update(scope_invocation=inv,scope_memory_peak=releases[0]['MEMORY_PEAK'])
    return p


def main():
    assert __debug__
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    root=scratch/'ventium-data-size.v2HaTO2X'
    old,new,core=root/'envfault-r2',root/'env-write-fault-r3',root/'env-write-core-r1'
    b=load(core/'build-closed.json');start=load(core/'build-started.json')
    assert b['passed'] and b['pins_unchanged'] and b['native_exit']==0
    assert all(sha(p)==h for p,h in start['pins'].items())
    assert sha(core/'obj/tb_ventium')==b['binary_sha256']
    parent=root/'core-r1';pstart=load(parent/'build-started.json')
    assert start['changes']==[recipe.FILE] and start['definitions']==pstart['definitions']
    assert (core/'candidate'/recipe.FILE).read_text()==recipe.transform((parent/'candidate'/recipe.FILE).read_text())
    names={str(Path(p).relative_to(parent/'candidate')):h for p,h in pstart['pins'].items()
           if Path(p).is_relative_to(parent/'candidate')}
    assert len(names)==195
    assert [n for n,h in names.items() if sha(core/'candidate'/n)!=h]==[recipe.FILE]
    host=Path(start['host']);obj=core/'obj'
    assert (obj/(host.stem+'.o')).is_file()
    headers=[Path(n) for n in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
             if Path(n).name=='Vventium_top___024root.h']
    assert len(headers)==1 and (headers[0] if headers[0].is_absolute() else obj/headers[0]).resolve()==(obj/'Vventium_top___024root.h')
    command=(obj/'Vventium_top__verFiles.dat').read_text()
    assert '-GAXI_LINE_REPLAY=0' in command and set(re.findall(r'\+define\+(\w+)',command))==set(start['definitions'])
    owners={'build':owner('ventium-env-write-core-oct13-r1.service',start['invocation'],0,'env-write-core-r1')}
    expected={tuple(sorted(dict(FULL=f,ENV16=w,HEAD=h,PRESENT=p,INJECT=0).items()))
              for f,w,h,p in itertools.product((0,1),(0,1),range(5),(0,1))}
    expected|={tuple(sorted(dict(FULL=f,ENV16=w,HEAD=4,PRESENT=1,INJECT=1).items()))
               for f,w in itertools.product((0,1),(0,1))}
    rows={};pincount=0
    for label,folder,unit,code in [('old',old,'ventium-data-size-envfault-oct13-r2.service',1),
                                  ('new',new,'ventium-env-write-fault-oct13-r3.service',0)]:
        begun,closed=load(folder/'started.json'),load(folder/'closed.json')
        assert closed['pins_unchanged'] and not closed['errors'] and closed['passed']==(label=='new')
        owners[label]=owner(unit,begun['invocation'],code)
        assert all(closed['memory_events'][k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
        for p,h in begun['pins'].items():
            actual=folder/'driver_source.py' if label=='old' and Path(p)==HERE/'run_fault.py' else Path(p)
            assert sha(actual)==h,(label,p)
            pincount+=1
        assert all(sha(folder/p)==h for p,h in closed['artifacts'].items())
        assert Path(begun['model'])==(parent if label=='old' else core)/'obj/tb_ventium'
        assert set(begun['definitions'])==set(start['definitions'])
        assert sha(begun['qemu'])=='f09369f734347c6ca0baf73b3edac8218c482b2fc1cd33c31b3e6672b7e51202'
        mapped={tuple(sorted(r['case'].items())):r for r in closed['rows']}
        assert len(closed['rows'])==len(mapped)==44 and set(mapped)==expected
        for key,r in mapped.items():
            c=r['case'];leaf=folder/('-'.join(k.lower()+str(v) for k,v in c.items()))
            assert sha(leaf/'fixture.bin')==r['image_sha256']
            assert r['qemu_exit']==(135 if c['INJECT'] else 133) and r['golden_exit']==0
            for stem,expected_exit in [('qemu',r['qemu_exit']),('golden',r['golden_exit'])]:
                receipt=load(leaf/(stem+'.native.json'));argv=load(leaf/(stem+'.command.json'))
                assert receipt['exit']==expected_exit and receipt['child_reaped'] and receipt['observed_affinity']
                cpu=int(argv[2]);assert 13<=cpu<=16
                assert all(v==[cpu] for v in receipt['observed_affinity'].values())
                assert begun['qemu'] in argv and str(leaf/'fixture.bin') in argv
                assert argv[argv.index('--cpu' if stem=='golden' else '-cpu')+1]=='pentium'
            assert [m['latency'] for m in r['rows']]==[0,7]
            for m in r['rows']:
                stem='rtl-l'+str(m['latency']);native=load(leaf/(stem+'.native.json'))
                argv=load(leaf/(stem+'.command.json'))
                assert native['exit']==m['rtl_exit'] and native['child_reaped'] and native['observed_affinity']
                cpu=int(argv[2]);assert 13<=cpu<=16
                assert all(v==[cpu] for v in native['observed_affinity'].values())
                assert '--cycle-func' in argv and '--l1-axi' in argv
                assert begun['model'] in argv and str(leaf/'fixture.bin') in argv
                assert not {'--dbg-step','--dbg-bp','--no-trace','--snapshot-in'}&set(argv)
                actual=tracefmt.read_trace(str(leaf/(stem+'.vtrace')))
                assert actual.sys and not actual.x87 and len(actual.records)==m['records']
                result=subprocess.run([sys.executable,'-B',str(REPO/'verif/diff/compare.py'),
                    '--mode','func','--all',str(leaf/'golden.vtrace'),str(leaf/(stem+'.vtrace'))],
                    stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=20)
                assert result.returncode==m['compare_exit']
                should_fail=label=='old' and c['HEAD'] and not c['INJECT']
                assert m['rtl_self_check']==(not should_fail) and m['compare_exit']==int(bool(should_fail))
                assert m['paired_v']>0 and m['backing_acks']>0
                assert int(actual.records[-1]['eax'],16)&255==(0x43 if should_fail or c['INJECT'] else 0x42)
        rows[label]=mapped
    assert all(rows['old'][k]['image_sha256']==rows['new'][k]['image_sha256'] for k in expected)
    paths=[Path(__file__),HERE/'prepare_write_class.py',core/'build-started.json',core/'build-closed.json',
           old/'started.json',old/'closed.json',new/'started.json',new/'closed.json']
    result=dict(passed=True,owners=owners,checked_pins=pincount,source_files=195,changed_files=[recipe.FILE],
        positive_fault_measurements=64,boundary_controls=16,negative_fixture_measurements=8,
        parent_fault_failures=64,candidate_fault_failures=0,full_comparisons_repeated=176,
        artifact_pins={str(p):sha(p) for p in paths},standard_suite=False,physical_board=False,gameplay_ipc=None)
    with (root/'env-write-audit.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
