"""Audit full-core transfer and both functional-reference/canonical closures."""
import argparse
import contextlib
import hashlib
import io
import json
from pathlib import Path
import os
import re
import subprocess
import sys
import prepare

REPO=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt
import compare


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def load(p):return json.loads(p.read_text())


def owner(unit,started,code,scope=False):
    keys=('MainPID','ExecMainStatus','InvocationID','MemoryPeak',
          'ExecMainStartTimestampMonotonic','ExecMainExitTimestampMonotonic')
    command=['systemctl','--user','show',unit]
    for key in keys:command+=['-p',key]
    result=dict(s.split('=',1) for s in subprocess.check_output(command,text=True).splitlines())
    assert result['MainPID']=='0' and int(result['ExecMainStatus'])==code
    if scope:
        events=[json.loads(line) for line in subprocess.check_output(['journalctl','--user',
            '--no-pager','-o','json','USER_INVOCATION_ID='+started['invocation']],text=True).splitlines()]
        starts=[e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and e.get('JOB_TYPE')=='start']
        stops=[e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and 'MEMORY_PEAK' in e]
        assert len(starts)==len(stops)==1 and starts[0]['JOB_RESULT']=='done'
        assert int(result['ExecMainStartTimestampMonotonic'])<=int(starts[0]['__MONOTONIC_TIMESTAMP'])<int(stops[0]['__MONOTONIC_TIMESTAMP'])<=int(result['ExecMainExitTimestampMonotonic'])
        result.update(scope_invocation=started['invocation'],scope_memory_peak=stops[0]['MEMORY_PEAK'],
                      scope_swap_peak=stops[0].get('MEMORY_SWAP_PEAK'))
    else:assert result['InvocationID']==started['invocation']
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--root',type=Path,required=True)
    a=ap.parse_args();root=a.root.resolve(strict=True);core=root/'core-r1';func=root/'func-r1'
    assert __debug__ and os.sched_getaffinity(0)=={12}
    assert not (root/'audit-core.json').exists()
    started,built=load(core/'build-started.json'),load(core/'build-closed.json')
    fs,fc=load(func/'started.json'),load(func/'closed.json')
    vs,vc=load(core/'verify-started.json'),load(core/'verify-closed.json')
    leaf=load(root/'leaf-r3/audit.json'); assert leaf['passed']
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert fc['passed'] and fc['pins_unchanged'] and len(fc['rows'])==108 and all(r['passed'] for r in fc['rows'])
    assert vc['pins_unchanged'] and vc['canonical_gate_native_exit'] in (0,2)
    assert fc['memory_events']['oom']==fc['memory_events']['oom_kill']=='0'
    owners=dict(build=owner('ventium-frndint-core-oct13-r1.service',started,0,True),
                functional=owner('ventium-frndint-func-oct13-r1.service',fs,0),
                canonical=owner('ventium-frndint-verify-oct13-r1.service',vs,int(vc['canonical_gate_native_exit']!=0)))
    pins={}
    for record in (started,fs,vs):
        for p,h in record['pins'].items():
            assert p not in pins or pins[p]==h
            pins[p]=h
    assert all(sha(p)==h for p,h in pins.items())
    parent=Path(started['parent']);source=parent/'candidate'
    names=sorted(str(p.relative_to(source)) for p in source.rglob('*') if p.is_file())
    assert len(names)==195 and len(started['definitions'])==152
    for n in names:
        expected=prepare.transform((source/n).read_text(),n).encode() if n in prepare.PARENTS else (source/n).read_bytes()
        assert (core/'candidate'/n).read_bytes()==expected
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']==fs['model']
    host=Path(started['host']);assert (core/'obj'/(host.stem+'.o')).is_file()
    deps=(core/'obj'/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
    assert [Path(n).name for n in deps].count('Vventium_top___024root.h')==1
    assert Path(built['private_header']).resolve()==(core/'obj/Vventium_top___024root.h').resolve()
    goldens={}
    for p in (func/'private-enabled-cache').glob('*.vtrace'):
        trace=tracefmt.read_trace(str(p));name=re.search(r'elf=(\w+)\.func\.elf ',trace.hdr['note']).group(1)
        assert name not in goldens;goldens[name]=p
    assert len(goldens)==108
    records=paired=0;raw_fail=[]
    for job,row in zip(fs['jobs'],fc['rows']):
        name=job[1];assert row['name']==name and row['actual_wait'] and row['error'] is None
        assert row['native_worker_exit']==0 and row['affinity_verified']
        cpu=int(row['command'][2])
        assert {v['executable'] for v in row['observed_affinity'].values()}=={'tb_ventium','qemu-i386'}
        assert all(v['affinity']==[cpu] for v in row['observed_affinity'].values())
        rtl=func/'work'/(name+'.func_rtl.vtrace')
        r,g=tracefmt.read_trace(str(rtl)),tracefmt.read_trace(str(goldens[name]))
        assert len(r.records)==len(g.records) and r.x87==g.x87==bool(int(job[6]))
        records+=len(r.records);manifest=load(Path(job[2]).parent/'manifest.json');args=['--mode','func']
        def fmt(v):return f'{v[0]}:{"" if len(v)<2 or v[1] is None else v[1]}'+(f'={v[2]}' if len(v)>=3 and v[2] else '')
        for key,mask in (('x87_fprem1_cc_ranges','0x4300'),('x87_stkflt_fstat_ranges','0x4741')):
            if manifest.get(key):
                args+=['--mask-fstat-exc',mask]
                for v in manifest[key]:args+=['--mask-fstat-range',fmt(v)]
        for v in manifest.get('x87_stkflt_fpr_ranges',[]):args+=['--mask-fpr-range',fmt(v)]
        if len(args)==2 and manifest.get('x87_stkflt_arch'):args+=['--mask-fstat-exc','0x4741','--mask-x87-fpr']
        with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
            rc=compare.main([*args,str(goldens[name]),str(rtl)])
            raw=compare.main(['--mode','func',str(goldens[name]),str(rtl)])
        assert rc==0
        if raw:raw_fail.append(name)
        log=(func/'work'/(name+'.func_rtl.log')).read_text()
        assert '--l1-axi selected' in log
        pair=re.search(r'pairedV=(\d+)',log);assert pair;paired+=int(pair[1])
        if name=='tx_regform':
            assert r.records[15]['fstat']==g.records[15]['fstat']=='0x0220'
            assert r.records[15]['st0']==g.records[15]['st0']=='0x40008000000000000000'
    assert records==80800 and paired>0
    old=sorted((parent/'generic-work').glob('*.cycle_rtl.vtrace'))
    new=sorted((core/'generic-work').glob('*.cycle_rtl.vtrace'))
    assert len(old)==len(new)==20
    for a,b in zip(old,new):
        assert a.name==b.name and tracefmt.read_trace(str(a)).records==tracefmt.read_trace(str(b)).records
    assert all(sha(p)==h for p,h in pins.items())
    artifacts={str(p):sha(p) for p in func.rglob('*') if p.is_file()}
    for p in (core/'build-started.json',core/'build-closed.json',core/'verify-started.json',
              core/'verify-closed.json',root/'leaf-r3/audit.json',Path(__file__)):
        artifacts[str(p)]=sha(p)
    result=dict(passed=True,owners=owners,pins_checked=len(pins),source_files=195,
        functional_passes=108,complete_records=records,v_retirements=paired,
        unmasked_passes=108-len(raw_fail),unmasked_failures=raw_fail,
        original_frndint_failure_repaired=True,cycle_traces_unchanged=20,
        canonical_gate_native_exit=vc['canonical_gate_native_exit'],canonical_gate_passed=vc['canonical_gate_passed'],
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None,artifacts=artifacts)
    with (root/'audit-core.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'},indent=2))


if __name__=='__main__':main()
