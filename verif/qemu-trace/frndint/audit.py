"""Independent closure, source, native/exact and complete-trace audit."""
import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys

import prepare
import run_state

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO/'verif/sys/frndint'))
import vectors
sys.path.insert(0, str(REPO/'verif/diff'))
import compare
import tracefmt


def load(p):
    return json.loads(p.read_text())


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__); ap.add_argument('--root',type=Path,required=True)
    a=ap.parse_args(); root=a.root.resolve(strict=True)
    assert __debug__ and os.sched_getaffinity(0)=={12} and not(root/'audit.json').exists()
    pins={}; owners={}; closures={}
    for label in ('build','probe','integrated','aligned','func','c1','state'):
        folder=root/(label+'-r1'); started=load(folder/'started.json'); closed=load(folder/'closed.json')
        expected=int(label=='integrated')
        command=['systemctl','--user','show','ventium-qemu-frndint-'+label+'-oct13-r1.service']
        for key in ('MainPID','SubState','ExecMainStatus','InvocationID','MemoryPeak',
                    'ExecMainStartTimestampMonotonic','ExecMainExitTimestampMonotonic'):
            command+=['-p',key]
        owner=dict(line.split('=',1) for line in subprocess.check_output(command,text=True).splitlines())
        assert owner['MainPID']=='0' and owner['SubState']==('failed' if expected else 'exited')
        assert owner['ExecMainStatus']==str(expected) and closed['pins_unchanged']
        assert closed['passed']==(not expected)
        if label=='build':
            events=[json.loads(s) for s in subprocess.check_output(['journalctl','--user','--no-pager',
                '-o','json','USER_INVOCATION_ID='+started['invocation']],text=True).splitlines()]
            starts=[e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and e.get('JOB_TYPE')=='start']
            stops=[e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and 'MEMORY_PEAK' in e]
            assert len(starts)==len(stops)==1 and starts[0]['JOB_RESULT']=='done'
            assert root.name in starts[0]['MESSAGE']
            assert int(owner['ExecMainStartTimestampMonotonic'])<=int(starts[0]['__MONOTONIC_TIMESTAMP'])<int(stops[0]['__MONOTONIC_TIMESTAMP'])<=int(owner['ExecMainExitTimestampMonotonic'])
            owner.update(scope_invocation=started['invocation'],scope_memory_peak=stops[0]['MEMORY_PEAK'],scope_swap_peak=stops[0].get('MEMORY_SWAP_PEAK'))
        else:
            assert owner['InvocationID']==started['invocation']
        for p,h in started['pins'].items():
            assert p not in pins or pins[p]==h
            pins[p]=h
        owners[label]=owner; closures[label]=closed
    assert all(sha(p)==h for p,h in pins.items())
    build=root/'build-r1'; inventory=load(build/'source.json'); parent=Path(load(build/'started.json')['parent'])
    assert inventory['changed']==[prepare.HELPER] and len(inventory['after'])==11132
    derived=prepare.transform((parent/'source'/prepare.HELPER).read_text())
    for name,h in inventory['after'].items():
        assert sha(build/'source'/name)==h
        if name==prepare.HELPER: assert (build/'source'/name).read_text()==derived
        else: assert h==inventory['before'][name]
    assert sha(closures['build']['binary'])==closures['build']['sha256']
    probe=root/'probe-r1'; rows=load(probe/'cases.json')
    assert rows==vectors.rows() and len(rows)==28684
    values={name:list(struct.iter_unpack('<4I',(probe/(name+'.bin')).read_bytes())) for name in ('native','control','candidate')}
    assert all(len(v)==len(rows) for v in values.values())
    exact=0; parent_bad=set()
    for i,(r,n,c,old) in enumerate(zip(rows,values['native'],values['candidate'],values['control'])):
        if r['kind']:
            assert old==c
        else:
            assert n[:3]==c[:3] and not((n[3]^c[3])&0x82ff)
            if old[:3]!=n[:3] or (old[3]^n[3])&0x82ff: parent_bad.add(i)
        e=vectors.finite_result(r)
        if e is not None:
            number,flags=e; exact+=1
            assert n[0]|n[1]<<32|n[2]<<64==number and not((n[3]^flags)&0x82ff)
    assert exact==27072 and parent_bad
    with (probe/'stdin.bin').open('rb') as f:
        native=subprocess.run([probe/'native'],stdin=f,capture_output=True,timeout=30)
    assert native.returncode==0 and native.stdout==(probe/'native.bin').read_bytes() and not native.stderr
    state=root/'state-r1'; sr=load(state/'cases.json')
    assert sr==json.loads(json.dumps(run_state.cases()))
    n=(state/'native.bin').read_bytes(); c=(state/'candidate.bin').read_bytes()
    assert len(n)==len(c)==108*len(sr)
    for i in range(len(sr)):
        nr=n[108*i:108*i+108]; cr=c[108*i:108*i+108]
        nw=struct.unpack('<27I',nr); cw=struct.unpack('<27I',cr)
        assert not((nw[0]^cw[0])&0xffff or (nw[1]^cw[1])&0xbaff or (nw[2]^cw[2])&0xffff)
        assert nr[28:]==cr[28:]
    with (state/'stdin.bin').open('rb') as f:
        native=subprocess.run([state/'probe'],stdin=f,capture_output=True,timeout=30)
    assert native.returncode==0 and native.stdout==n and not native.stderr
    c1=root/'c1-r1'; crows=load(c1/'cases.json'); assert len(crows)==34200
    cvals={name:list(struct.iter_unpack('<4I',(c1/(name+'.bin')).read_bytes())) for name in ('native','control','candidate')}
    for i,r in enumerate(crows):
        target=r['expected']<<9 if r['mask']==0x200 else r['expected']
        for name in ('native','candidate'):
            assert cvals[name][i][3]&r['mask']==target
            assert cvals[name][i][:3]==cvals['control'][i][:3]
        assert not((cvals['candidate'][i][3]^cvals['control'][i][3])&~r['mask'])
    failed=root/'integrated-r1'
    assert closures['integrated']['completed_cases']==412 and closures['integrated']['guest_exit']==0
    assert 'field=esp:' in (failed/'compare.log').read_text()
    aligned=root/'aligned-r1'
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        assert compare.main(['--mode','func',str(aligned/'qemu.vtrace'),str(aligned/'rtl.vtrace')])==0
    qt=tracefmt.read_trace(str(aligned/'qemu.vtrace')).records
    rt=tracefmt.read_trace(str(aligned/'rtl.vtrace')).records
    assert len(qt)==len(rt)==11129 and qt[0]['esp']==rt[0]['esp']==closures['aligned']['initial_esp']
    assert closures['aligned']['actual_v_retirements']==2474
    assert all(int(t[-1]['ebx'],16)==0 and int(t[-1]['ebp'],16)==412 for t in (qt,rt))
    func=root/'func-r1'; fs=load(func/'started.json'); fc=closures['func']
    assert len(fc['rows'])==108 and all(r['passed'] for r in fc['rows'])
    assert fc['memory_events']['oom']==fc['memory_events']['oom_kill']=='0'
    goldens={}
    for p in (func/'private-enabled-cache').glob('*.vtrace'):
        t=tracefmt.read_trace(str(p)); name=re.search(r'elf=(\w+)\.func\.elf ',t.hdr['note']).group(1)
        assert name not in goldens; goldens[name]=p
    assert len(goldens)==108
    records=paired=raw_passed=0
    for job,row in zip(fs['jobs'],fc['rows']):
        name=job[1]; assert row['name']==name and row['actual_wait'] and row['error'] is None
        assert row['native_worker_exit']==0 and row['affinity_verified']
        cpu=int(row['command'][2])
        assert {r['executable'] for r in row['observed_affinity'].values()}=={'tb_ventium','qemu-i386'}
        assert all(r['affinity']==[cpu] for r in row['observed_affinity'].values())
        rtl=func/'work'/(name+'.func_rtl.vtrace')
        r,g=tracefmt.read_trace(str(rtl)),tracefmt.read_trace(str(goldens[name]))
        assert len(r.records)==len(g.records) and r.x87==g.x87==bool(int(job[6])); records+=len(r.records)
        manifest=load(Path(job[2]).parent/'manifest.json'); args=['--mode','func']
        def fmt(v):
            return f'{v[0]}:{"" if len(v)<2 or v[1] is None else v[1]}'+(f'={v[2]}' if len(v)>=3 and v[2] else '')
        for key,mask in (('x87_fprem1_cc_ranges','0x4300'),('x87_stkflt_fstat_ranges','0x4741')):
            if manifest.get(key):
                args+=['--mask-fstat-exc',mask]
                for v in manifest[key]: args+=['--mask-fstat-range',fmt(v)]
        for v in manifest.get('x87_stkflt_fpr_ranges',[]): args+=['--mask-fpr-range',fmt(v)]
        if len(args)==2 and manifest.get('x87_stkflt_arch'): args+=['--mask-fstat-exc','0x4741','--mask-x87-fpr']
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            assert compare.main([*args,str(goldens[name]),str(rtl)])==0
            raw_passed+=compare.main(['--mode','func',str(goldens[name]),str(rtl)])==0
        log=(func/'work'/(name+'.func_rtl.log')).read_text()
        assert '--l1-axi selected' in log
        paired+=int(re.search(r'pairedV=(\d+)',log).group(1))
    assert records==80800 and paired==30134 and raw_passed==105
    artifacts={str(p):sha(p) for p in root.rglob('*') if p.is_file() and
               'build-r1/source/' not in str(p) and 'build-r1/build/' not in str(p)}
    result=dict(passed=True,owners=owners,input_pins=len(pins),source_files=11132,changed=[prepare.HELPER],
        frndint_cases=28612,parent_frndint_failures=len(parent_bad),exact_cases=exact,
        state_cases=len(sr),following_fadd_cases=sum(r[-1]==1 for r in sr),c1_regression_cases=34200,
        cold_trace_records=11129,cold_cases=412,cold_v_retirements=2474,
        functional_passes=108,full_unmasked_functional_passes=raw_passed,functional_records=records,
        functional_v_retirements=paired,artifacts=artifacts,canonical_gate_passed=False,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,synthesized_fmax_mhz=None)
    with (root/'audit.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'},indent=2))


if __name__=='__main__': main()
