"""Independently regrade complete records and the private one-file source delta.

Keep canonical failures and the existing three x87 stack-fault masking cases
visible. This audit is evidence integrity, not standard-suite/FPGA acceptance.
"""
import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import prepare_fetch_metadata_owner as recipe
from build_fetch_metadata_core import MODEL as PARENT_MODEL

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt
import compare


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def load(p):return json.loads(p.read_text())


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--data',type=Path,required=True)
    data=ap.parse_args().data.resolve(strict=True)
    assert __debug__ and os.sched_getaffinity(0)=={21}
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve()==scratch and data.is_relative_to(scratch)
    pins={}
    def pin(p):pins[str(p.resolve())]=sha(p)
    def pincheck(more):
        for name,digest in more.items():
            p=Path(name);assert sha(p)==digest,(name,'pin drift');pins[name]=digest
    def checked(folder,start='started.json',end='closed.json'):
        s,c=load(folder/start),load(folder/end)
        assert c['passed'] and c['pins_unchanged'] and not c.get('errors')
        pincheck(s['pins']);pin(folder/start);pin(folder/end)
        return s,c
    leaf=data/'fetch-metadata-leaf-r1';ls,lc=checked(leaf)
    assert lc['outputs']==122 and len(lc['native'])==4
    assert [r['exit'] for r in lc['native']]==[0,0,1,1]
    for row in lc['native']:
        assert row['actual_wait'] and row['reaped'] and row['affinity']==[14]
        assert sha(row['log'])==row['sha256'];pin(Path(row['log']))
    assert 'FETCH-METADATA-OK checks=524288 inactive_differences=94576 mutant=0' in (leaf/'run.log').read_text()
    for n in (1,2):assert 'FETCH-METADATA-MISMATCH' in (leaf/f'mutant-{n}.log').read_text()
    core=data/'fetch-metadata-core-r1';cs,cc=checked(core,'build-started.json','build-closed.json')
    parent=Path(cs['parent'])
    assert cs['parent_model']==sha(parent/'obj/tb_ventium')==PARENT_MODEL
    assert cc['native_exit']==0 and sha(core/'obj/tb_ventium')==cc['binary_sha256']
    assert cs['changes']==[recipe.FILE] and len(cs['definitions'])==152
    assert '--assert' in next(x for x in cs['command'] if x.startswith('VL_EXTRA_DEFINES='))
    assert '-GAXI_LINE_REPLAY=0' in ' '.join(cs['command'])
    assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()
    assert (leaf/'core.sv').read_text()==(core/'candidate'/recipe.FILE).read_text()
    rel=[str(Path(p).relative_to(core/'candidate')) for p in cs['pins'] if Path(p).is_relative_to(core/'candidate')]
    assert len(rel)==195 and len(set(rel))==195
    assert [n for n in rel if sha(parent/'candidate'/n)!=sha(core/'candidate'/n)]==[recipe.FILE]
    func=data/'fetch-metadata-func-r1';fs,fc=checked(func)
    replay=data/'fetch-metadata-replay-r1';rs,rc=checked(replay)
    assert len(fc['rows'])==len(rc['rows'])==108
    gold={}
    for p in (func/'private-enabled-cache').glob('*.vtrace'):
        t=tracefmt.read_trace(str(p));name=re.search(r'elf=(\w+)\.func\.elf ',t.hdr['note'])[1]
        assert name not in gold;gold[name]=p
    assert len(gold)==108
    total=paired=0;strict_failures=[]
    for row in fc['rows']:
        name=row['name'];assert row['passed'] and row['native_worker_exit']==0 and row['actual_wait']
        assert row['affinity_verified'] and not row['error']
        rtl=func/'work'/(name+'.func_rtl.vtrace')
        r=tracefmt.read_trace(str(rtl));total+=len(r.records)
        with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
            if compare.main(['--mode','func',str(gold[name]),str(rtl)])!=0:strict_failures.append(name)
        for label in ('parent','candidate'):
            path=replay/name/(label+'.vtrace');pin(path)
            assert tracefmt.read_trace(str(path)).records==r.records
        rr=load(replay/name/'closed.json');assert rr['passed']
        assert rr['counts']['parent']==rr['counts']['candidate']
        assert all(x['native_exit']==0 and x['actual_wait'] and x['affinity_verified'] and not x['error'] for x in rr['native'])
        paired+=rr['counts']['candidate']['paired_v'];pin(rtl);pin(gold[name])
    assert (total,paired)==(80800,30132)
    assert sorted(strict_failures)==['tx_regform','tx_regform2','tx_stack']
    system=data/'fetch-metadata-system-r1';ss,sc=checked(system)
    assert len(sc['rows'])==5
    sys_records=sys_v=0
    for case in sc['rows']:
        folder=system/case['name'];assert case['passed'] and len(case['rows'])==6
        for latency in (0,7,31):
            p=folder/f'parent-lat{latency}.vtrace';q=folder/f'candidate-lat{latency}.vtrace'
            r=tracefmt.read_trace(str(q));assert r.records==tracefmt.read_trace(str(p)).records
            for path in (p,q):pin(path)
            if case['name']!='pfaststack_segenf':
                with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
                    assert compare.main(['--mode','func','--all',str(folder/'gold.vtrace'),str(q)])==0
                pin(folder/'gold.vtrace')
            native=[x for x in case['rows'] if x['latency']==latency]
            assert native[0]['counts']==native[1]['counts']
            assert all(x['native']['native_exit']==133 and x['native']['actual_wait'] and x['native']['affinity_observed'] for x in native)
            sys_records+=len(r.records);sys_v+=native[1]['counts']['v']
    boundary=data/'fetch-metadata-boundaries-r1';bs,bc=checked(boundary)
    assert len(bc['rows'])==8 and not bc['qemu_differential'] and not bc['original_gate_passed']
    boundary_records=boundary_v=0
    for case in bc['rows']:
        assert case['passed'] and len(case['rows'])==12
        for latency in (0,7,31):
            for mode in ('cycle-func','cycle'):
                folder=boundary/case['case']
                p=folder/f'parent-lat{latency}-{mode}.vtrace';q=folder/f'candidate-lat{latency}-{mode}.vtrace'
                r=tracefmt.read_trace(str(q));assert r.records==tracefmt.read_trace(str(p)).records
                for path in (p,q):pin(path)
                boundary_records+=len(r.records)
                boundary_v+=sum(x.get('paired') and x.get('pipe')=='V' for x in r.records) if mode=='cycle' else 0
        assert all(r['native']['native_exit']==133 and r['native']['actual_wait'] and r['native']['reaped'] for r in case['rows'])
    canonical=load(core/'verify-closed.json');pincheck(load(core/'verify-started.json')['pins'])
    assert canonical['canonical_gate_native_exit']==2 and not canonical['canonical_gate_passed'] and canonical['pins_unchanged']
    for p in (core/'generic-work').glob('*.cycle_rtl.vtrace'):
        assert tracefmt.read_trace(str(p)).records==tracefmt.read_trace(str(parent/'generic-work'/p.name)).records
        pin(p)
    assert len(canonical['deltas'])==20 and all(x['same_records'] for x in canonical['deltas'])
    verdicts=[p.read_text().split('|')[3] for p in (core/'generic-work').glob('*.func.result')]
    assert verdicts.count('PASS')==7 and verdicts.count('FAIL')==101
    for name in ('verify-started.json','verify-closed.json'):pin(core/name)
    owners={}
    for suffix in ('leaf','core','func','system','boundaries','replay','verify'):
        unit=f'ventium-fetch-metadata-{suffix}-oct15-r1.service'
        props=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
            '-p','SubState','-p','MainPID','-p','ExecMainStatus','-p','InvocationID'],text=True).splitlines())
        assert props['MainPID']=='0' and props['SubState']==('failed' if suffix=='verify' else 'exited')
        assert props['ExecMainStatus']==('1' if suffix=='verify' else '0');owners[unit]=props
    for suffix in ('func','replay','system'):
        stem=data/('fetch-metadata-'+suffix+'-r1')
        pincheck(load(stem.with_suffix('.driver.json'))['pins'])
        c=load(stem.with_suffix('.driver-closed.json'));assert c['native_exit']==0 and c['pins_unchanged']
    pincheck(load(boundary.with_suffix('.adapter.json'))['pins'])
    for p in (Path(__file__),Path(recipe.__file__),Path(tracefmt.__file__),Path(compare.__file__)):pin(p)
    assert all(sha(p)==h for p,h in pins.items())
    out=data/'fetch-metadata-audit.json'
    with out.open('x') as f:json.dump(dict(passed=True,input_pins=len(pins),pins=pins,owners=owners,
        model_sha256=cc['binary_sha256'],metadata_vectors=524288,functional_passes=108,
        strict_functional_failures=strict_failures,records=total,v_retirements=paired,
        system_records=sys_records,system_v=sys_v,boundary_records=boundary_records,boundary_v=boundary_v,
        canonical_pass=7,canonical_fail=101,identical_cycle_streams=20,
        sampled_cycle_gain_percent=0,gameplay_ipc=None,fmax_mhz=None,
        standard_suite=False,hardware_acceptance=False),f,indent=2)
    print('FETCH-METADATA-AUDIT-OK',len(pins),cc['binary_sha256'],flush=True)


if __name__=='__main__':main()
