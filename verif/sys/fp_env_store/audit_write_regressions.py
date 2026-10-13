"""Recheck complete functional/cycle records, retaining canonical failures."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(REPO/'verif/diff'))
import compare
import tracefmt


def load(p):return json.loads(p.read_text())


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def equivalent(gold,rtl,options=()):
    with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
        return compare.main(['--mode','func',*options,str(gold),str(rtl)])==0


def main():
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    root=scratch/'ventium-data-size.v2HaTO2X'
    core,func,parent=root/'env-write-core-r1',root/'env-write-func-r1',root/'core-r1'
    fs,fc=load(func/'started.json'),load(func/'closed.json')
    vs,vc=load(core/'verify-started.json'),load(core/'verify-closed.json')
    assert fc['passed'] and fc['pins_unchanged'] and len(fc['rows'])==108
    assert all(fc['memory_events'][k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    assert vc['pins_unchanged'] and vc['canonical_gate_native_exit'] in (0,2)
    assert vc['canonical_gate_passed']==(vc['canonical_gate_native_exit']==0)
    assert not vc['masks_or_goldens_or_bands_changed']
    pins={};owners={}
    for label,started,code in [('func',fs,0),('canonical',vs,int(not vc['canonical_gate_passed']))]:
        props=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',
            'ventium-env-write-'+label+'-oct13-r1.service','-pMainPID','-pSubState',
            '-pExecMainStatus','-pInvocationID'],text=True,timeout=5).splitlines())
        assert props==dict(MainPID='0',SubState='failed' if code else 'exited',
            ExecMainStatus=str(code),InvocationID=started['invocation'])
        owners[label]=props;pins.update(started['pins'])
        driver=load(root/('env-write-'+label+'-r1.driver.json'))
        closed=load(root/('env-write-'+label+'-r1.driver-closed.json'))
        assert closed['pins_unchanged'] and closed['native_exit']==code
        assert driver['unmodified_comparisons']
        pins.update(driver['pins'])
    assert all(sha(p)==h for p,h in pins.items())
    assert sha(core/'obj/tb_ventium')==fs['model']=='360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779'
    assert fs['environment']['TB_EXTRA_FLAGS']=='--cycle-func --l1-axi'
    assert fs['environment']['AXI_RLAT']==fs['environment']['AXI_WLAT']=='7'
    assert vs['environment']['TB_CYCLE_EXTRA_FLAGS']=='--l1-axi'
    goldens={}
    for p in (func/'private-enabled-cache').glob('*.vtrace'):
        t=tracefmt.read_trace(str(p));name=re.search(r'elf=(\w+)\.func\.elf ',t.hdr['note'])[1]
        assert name not in goldens;goldens[name]=p
    assert len(goldens)==108
    records=paired=0;unmasked_failures=[]
    for job,row in zip(fs['jobs'],fc['rows']):
        name=job[1];assert row['name']==name and row['passed'] and row['actual_wait']
        assert row['error'] is None and row['native_worker_exit']==0 and row['affinity_verified']
        cpu=int(row['command'][2]);assert 13<=cpu<=16
        assert {v['executable'] for v in row['observed_affinity'].values()}=={'qemu-i386','tb_ventium'}
        assert all(v['affinity']==[cpu] for v in row['observed_affinity'].values())
        rtl=func/'work'/(name+'.func_rtl.vtrace');gold=goldens[name]
        r,g=tracefmt.read_trace(str(rtl)),tracefmt.read_trace(str(gold))
        assert len(r.records)==len(g.records) and r.x87==g.x87==bool(int(job[6]))
        records+=len(r.records)
        manifest=load(Path(job[2]).parent/'manifest.json');options=[]
        def fmt(v):
            return f'{v[0]}:{"" if len(v)<2 or v[1] is None else v[1]}'+(f'={v[2]}' if len(v)>=3 and v[2] else '')
        for key,mask in (('x87_fprem1_cc_ranges','0x4300'),('x87_stkflt_fstat_ranges','0x4741')):
            if manifest.get(key):
                options+=['--mask-fstat-exc',mask]
                for v in manifest[key]:options+=['--mask-fstat-range',fmt(v)]
        for v in manifest.get('x87_stkflt_fpr_ranges',[]):options+=['--mask-fpr-range',fmt(v)]
        if not options and manifest.get('x87_stkflt_arch'):options+=['--mask-fstat-exc','0x4741','--mask-x87-fpr']
        assert equivalent(gold,rtl,options)
        if not equivalent(gold,rtl):unmasked_failures.append(name)
        log=(func/'work'/(name+'.func_rtl.log')).read_text()
        assert '--l1-axi selected' in log
        paired+=int(re.search(r'pairedV=(\d+)',log)[1])
    assert records==80800 and paired==30134
    assert set(unmasked_failures)=={'tx_regform','tx_regform2','tx_stack'}
    old=sorted((parent/'generic-work').glob('*.cycle_rtl.vtrace'))
    new=sorted((core/'generic-work').glob('*.cycle_rtl.vtrace'))
    assert len(old)==len(new)==len(vc['deltas'])==20
    assert all(r['same_records'] for r in vc['deltas'])
    for a,b in zip(old,new):
        assert a.name==b.name and tracefmt.read_trace(str(a)).records==tracefmt.read_trace(str(b)).records
    verdicts=[p.read_text().strip().split('|')[3] for p in (core/'generic-work').glob('*.func.result')]
    assert len(verdicts)==108 and set(verdicts)<= {'PASS','FAIL'}
    assert all(sha(p)==h for p,h in pins.items())
    artifacts={str(p):sha(p) for directory in (func,core/'generic-work') for p in directory.rglob('*') if p.is_file()}
    for p in (Path(__file__),core/'verify-started.json',core/'verify-closed.json'):
        artifacts[str(p)]=sha(p)
    result=dict(audit_passed=True,owners=owners,pins_checked=len(pins),artifacts=artifacts,
        functional_passes=108,unmasked_functional_passes=105,unmasked_failures=unmasked_failures,
        functional_records=records,v_retirements=paired,cycle_traces_unchanged=20,
        canonical_functional_passes=verdicts.count('PASS'),canonical_functional_failures=verdicts.count('FAIL'),
        canonical_gate_passed=vc['canonical_gate_passed'],canonical_gate_native_exit=vc['canonical_gate_native_exit'],
        standard_suite=False,physical_board=False,gameplay_ipc=None)
    with (root/'env-write-regression-audit.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'},indent=2))


if __name__=='__main__':main()
