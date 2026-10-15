"""Regrade closed remainder evidence; never promote QEMU, RTL, or FPGA state."""
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

import oracle
import precision_oracle
import prepare
REPO=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(REPO/'verif/srt'))
import prepare_remainder_exact as rtl_recipe
import run_remainder_exact as rtl_check
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt
import compare


def load(p):return json.loads(p.read_text())


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def owner(unit,exit_code):
    props=('ActiveState','SubState','MainPID','InvocationID','ExecMainStatus','MemoryPeak','Result')
    cmd=['systemctl','--user','show',unit]
    for key in props:cmd+=['-p',key]
    r=dict(line.split('=',1) for line in subprocess.check_output(cmd,text=True).splitlines())
    assert r['MainPID']=='0' and r['ExecMainStatus']==str(exit_code)
    assert r['SubState']==('failed' if exit_code else 'exited')
    return r


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--root',required=True,type=Path)
    args=ap.parse_args();root=args.root.resolve(strict=True)
    assert __debug__ and os.sched_getaffinity(0)=={13}
    assert root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    assert not(root/'audit.json').exists()
    pins={};owners={}
    archived={str(REPO/'verif/qemu-trace/remainder_sequence/run_small_quotient.py'):
              root/'small-quotient-r2/original_run_small_quotient.py'}
    definitions=[('build-r1','ventium-qemu-fprem-build-oct15-r1',0,'started.json'),
        ('srt-r2','ventium-srt-remainder-exact-oct15-r2',0,'started.json'),
        ('core-r1','ventium-srt-remainder-core-oct15-r1',0,'build-started.json'),
        ('small-quotient-r2','ventium-fprem-small-quotient-oct15-r2',0,'started.json'),
        ('run-r2','ventium-qemu-fprem-sequence-oct15-r2',0,'started.json'),
        ('func-r1','ventium-srt-remainder-func-oct15-r1',0,'started.json'),
        ('core-r1','ventium-srt-remainder-verify-oct15-r1',1,'verify-started.json')]
    for directory,unit,exit_code,start_name in definitions:
        started=load(root/directory/start_name);owners[unit]=owner(unit+'.service',exit_code)
        for p,h in started['pins'].items():
            assert p not in pins or pins[p]==h
            pins[p]=h
        if unit in ('ventium-qemu-fprem-build-oct15-r1','ventium-srt-remainder-exact-oct15-r2','ventium-srt-remainder-core-oct15-r1'):
            # The guarded build's invocation belongs to its owned scope, not
            # the outer controller. Retain its actual journal peak and closure.
            events=[json.loads(line) for line in subprocess.check_output(['journalctl','--user',
                '--no-pager','-o','json','USER_INVOCATION_ID='+started['invocation']],text=True).splitlines()]
            stops=[e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and 'MEMORY_PEAK' in e]
            assert len(stops)==1
            owners[unit].update(scope_invocation=started['invocation'],scope_memory_peak=stops[0]['MEMORY_PEAK'],
                scope_swap_peak=stops[0].get('MEMORY_SWAP_PEAK'))
        else:assert owners[unit]['InvocationID']==started['invocation']
    owners['adjacent']=owner('ventium-qemu-fprem-adjacent-oct15-r1.service',0)
    for directory in ('frndint-r1','frndint-state-r1','c1-r1'):
        st=load(root/directory/'started.json');cl=load(root/directory/'closed.json')
        assert st['invocation']==owners['adjacent']['InvocationID'] and cl['passed'] and cl['pins_unchanged']
        pins.update(st['pins'])
    assert all(sha(archived.get(p,p))==h for p,h in pins.items())
    build=root/'build-r1';inventory=load(build/'source.json');built=load(build/'closed.json')
    parent=Path(load(build/'started.json')['parent'])
    assert built['passed'] and built['pins_unchanged'] and len(inventory['after'])==11132
    assert inventory['changed']==[prepare.HELPER]
    assert (build/'source'/prepare.HELPER).read_text()==prepare.transform((parent/'source'/prepare.HELPER).read_text())
    assert all(sha(build/'source'/n)==h for n,h in inventory['after'].items())
    assert sha(built['binary'])==built['sha256']
    ref=root/'run-r2';grades={}
    for mode,grader in (('sequence',oracle),('precision',precision_oracle)):
        rows=grader.cases();assert load(ref/mode/'cases.json')==json.loads(json.dumps(rows))
        for label in ('native','control','candidate'):
            native=load(ref/mode/(label+'.native.json'))
            assert native['native_exit']==0 and native['actual_wait'] and native['reaped']
            assert native['observed_affinity']==[[12]] and sha(ref/mode/(label+'.bin'))==native['sha256']
            checked=grader.grade(rows,(ref/mode/(label+'.bin')).read_bytes())
            assert json.loads(json.dumps(checked))==load(ref/mode/(label+'.graded.json'))
            assert checked['passed']==(mode=='precision' or label!='control')
            grades[mode+'-'+label]={k:v for k,v in checked.items() if k!='errors'}
            grades[mode+'-'+label]['mismatches']=len(checked['errors'])
    leaf=root/'srt-r2';rows=rtl_check.cases();assert load(leaf/'cases.json')==json.loads(json.dumps(rows))
    engine={}
    for label in ('control','candidate','unsplit'):
        native=load(leaf/label/'run.json');control=label=='control'
        assert native['native_exit']==int(control) and native['actual_wait'] and native['reaped']
        assert native['observed_affinity']==[[12]] and sha(leaf/label/'records.txt')==native['record_sha256']
        checked=rtl_check.grade(rows,leaf/label/'records.txt',allow_incomplete=control)
        saved=load(leaf/label/'graded.json')
        assert all(json.loads(json.dumps(v))==saved[k] for k,v in checked.items())
        assert checked['passed']==(not control)
        engine[label]={k:v for k,v in checked.items() if k!='errors'}
        engine[label]['mismatches']=len(checked['errors'])
    core=root/'core-r1';prepared=load(core/'prepared.json');closed=load(core/'build-closed.json')
    cp=Path(prepared['parent'])/'candidate';name='rtl/fpu/fpu_srt_div.sv'
    assert prepared['changes']==[name] and len(prepared['definitions'])==152
    assert (core/'candidate'/name).read_text()==rtl_recipe.transform((cp/name).read_text())
    assert (core/'candidate'/name).read_text()==(leaf/'candidate/fpu_srt_div.sv').read_text()
    assert closed['passed'] and closed['pins_unchanged'] and sha(core/'obj/tb_ventium')==closed['binary_sha256']
    cold=root/'small-quotient-r2'
    with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
        assert compare.main(['--mode','func',str(cold/'qemu.vtrace'),str(cold/'rtl.vtrace')])==0
    for label in ('qemu','rtl'):
        records=tracefmt.read_trace(str(cold/(label+'.vtrace'))).records
        assert len(records)==23 and int(records[-1]['ebx'],16)==0 and int(records[-1]['ebp'],16)==1
    assert load(cold/'closed.json')['actual_v_retirements']==3
    # Canonical failures remain failures; all 20 complete cycle records must
    # be byte-for-field equivalent to the unchanged faster parent.
    canonical=load(core/'verify-closed.json')
    assert canonical['canonical_gate_native_exit']==2 and not canonical['canonical_gate_passed']
    assert canonical['pins_unchanged'] and len(canonical['deltas'])==20
    assert all(r['same_records'] for r in canonical['deltas'])
    for p in sorted((core/'generic-work').glob('*.cycle_rtl.vtrace')):
        assert tracefmt.read_trace(str(p)).records==tracefmt.read_trace(str(cp.parent/'generic-work'/p.name)).records
    # Regrade every functional trace using the unchanged live manifest masks.
    func=root/'func-r1';fs=load(func/'started.json');fc=load(func/'closed.json')
    assert fc['passed'] and fc['pins_unchanged'] and len(fc['rows'])==108
    goldens={}
    for p in (func/'private-enabled-cache').glob('*.vtrace'):
        t=tracefmt.read_trace(str(p));name=re.search(r'elf=(\w+)\.func\.elf ',t.hdr['note']).group(1)
        assert name not in goldens;goldens[name]=p
    assert len(goldens)==108
    total=paired=unmasked=0
    for job,row in zip(fs['jobs'],fc['rows']):
        name=job[1];assert row['name']==name and row['passed'] and row['native_worker_exit']==0 and row['actual_wait']
        assert row['affinity_verified'] and not row['error']
        rtl=func/'work'/(name+'.func_rtl.vtrace');gold=goldens[name]
        r,g=tracefmt.read_trace(str(rtl)),tracefmt.read_trace(str(gold));assert len(r.records)==len(g.records)
        total+=len(r.records);manifest=load(Path(job[2]).parent/'manifest.json');args=['--mode','func']
        def fmt(v):return f'{v[0]}:{"" if len(v)<2 or v[1] is None else v[1]}'+(f'={v[2]}' if len(v)>=3 and v[2] else '')
        for key,mask in (('x87_fprem1_cc_ranges','0x4300'),('x87_stkflt_fstat_ranges','0x4741')):
            if manifest.get(key):
                args+=['--mask-fstat-exc',mask]
                for v in manifest[key]:args+=['--mask-fstat-range',fmt(v)]
        for v in manifest.get('x87_stkflt_fpr_ranges',[]):args+=['--mask-fpr-range',fmt(v)]
        if len(args)==2 and manifest.get('x87_stkflt_arch'):args+=['--mask-fstat-exc','0x4741','--mask-x87-fpr']
        with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
            assert compare.main([*args,str(gold),str(rtl)])==0
            unmasked+=compare.main(['--mode','func',str(gold),str(rtl)])==0
        log=(func/'work'/(name+'.func_rtl.log')).read_text();assert '--l1-axi selected' in log
        paired+=int(re.search(r'pairedV=(\d+)',log).group(1))
    assert total==80800 and unmasked==105 and paired>0
    artifacts={str(p):sha(p) for p in root.rglob('*') if p.is_file() and
        p.suffix in ('.json','.jsonl','.vtrace','.bin','.txt','.log','.py','.sv','.S') and
        not any(s in str(p) for s in ('/build-r1/source/','/build-r1/build/','/obj/','/core-r1/candidate/'))}
    result=dict(passed=True,input_pins=len(pins),owners=owners,qemu_sha256=built['sha256'],
        model_sha256=closed['binary_sha256'],reference=grades,engine=engine,cold_records=23,
        cold_v_retirements=3,functional_passes=108,full_unmasked_functional_passes=unmasked,
        functional_records=total,functional_v_retirements=paired,canonical_gate_passed=False,
        cycle_streams_parent_identical=20,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,artifacts=artifacts)
    with (root/'audit.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'},indent=2),flush=True)


if __name__=='__main__':main()
