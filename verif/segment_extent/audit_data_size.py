"""Independently audit the data-size cut, preserving the canonical gate verdict."""
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

import prepare_data_size as recipe

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import compare
import tracefmt
sys.path.insert(0,str(REPO/'verif/sys/tests/pfetchbound'))
import check_witness as fetch


def load(p): return json.loads(Path(p).read_text())
def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def owner(name,invocation,code,scope=None):
    keys=('MainPID','ExecMainStatus','InvocationID','SubState','MemoryPeak',
          'ExecMainStartTimestampMonotonic','ExecMainExitTimestampMonotonic')
    command=['systemctl','--user','show',name]
    for key in keys: command+=['-p',key]
    found=dict(line.split('=',1) for line in subprocess.check_output(command,text=True,timeout=5).splitlines())
    assert found['MainPID']=='0' and found['ExecMainStatus']==str(code)
    assert found['SubState']==('exited' if code==0 else 'failed')
    assert found['InvocationID']==invocation
    if scope:
        entries=[json.loads(line) for line in subprocess.check_output(['journalctl','--user','--no-pager',
            '-o','json','USER_INVOCATION_ID='+scope],text=True,timeout=10).splitlines()]
        starts=[r for r in entries if r.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and r.get('JOB_TYPE')=='start']
        stops=[r for r in entries if r.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and 'MEMORY_PEAK' in r]
        assert len(starts)==len(stops)==1 and starts[0]['JOB_RESULT']=='done'
        assert int(found['ExecMainStartTimestampMonotonic'])<=int(starts[0]['__MONOTONIC_TIMESTAMP'])<int(stops[0]['__MONOTONIC_TIMESTAMP'])<=int(found['ExecMainExitTimestampMonotonic'])
        found.update(scope_invocation=scope,scope_memory_peak=stops[0]['MEMORY_PEAK'],scope_swap_peak=stops[0].get('MEMORY_SWAP_PEAK'))
    return found


def equivalent(gold,rtl,options=()):
    with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
        return compare.main(['--mode','func',*options,str(gold),str(rtl)])==0


def main():
    ap=argparse.ArgumentParser(description=__doc__); ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root==scratch/'ventium-data-size.v2HaTO2X' and os.sched_getaffinity(0)=={12}
    assert not (root/'audit.json').exists()
    core,leaf,func,ft=root/'core-r1',root/'leaf-r1',root/'func-r1',root/'fetch-r2'
    cs,cc=load(core/'build-started.json'),load(core/'build-closed.json')
    ls,lc=load(leaf/'started.json'),load(leaf/'closed.json')
    fs,fc=load(func/'started.json'),load(func/'closed.json')
    vs,vc=load(core/'verify-started.json'),load(core/'verify-closed.json')
    assert cc['passed'] and cc['pins_unchanged'] and cc['native_exit']==0
    assert lc['passed'] and lc['pins_unchanged'] and not lc['errors']
    assert fc['passed'] and fc['pins_unchanged'] and len(fc['rows'])==108
    assert vc['pins_unchanged'] and vc['canonical_gate_native_exit'] in (0,2)
    assert vc['canonical_gate_passed']==(vc['canonical_gate_native_exit']==0)
    assert not vc['masks_or_goldens_or_bands_changed']
    assert fc['memory_events']['oom']==fc['memory_events']['oom_kill']=='0'
    owners={
        'leaf':owner('ventium-data-size-leaf-oct13-r1.service','d784f5d746934465b845e4baa57581bf',0,ls['invocation']),
        'core':owner('ventium-data-size-core-oct13-r1.service','0c3451c3fcbb4c31946b94409768ce33',0,cs['invocation']),
        'fetch':owner('ventium-data-size-fetch-oct13-r2.service','5b8b9811f0414b8d82e2429b3e3f3977',0),
        'func':owner('ventium-data-size-func-oct13-r1.service',fs['invocation'],0),
        'canonical':owner('ventium-data-size-canonical-oct13-r1.service',vs['invocation'],int(vc['canonical_gate_native_exit']!=0)),
    }
    pins={}
    for record in (cs,ls,lc,fs,vs):
        for p,h in record['pins'].items():
            assert p not in pins or pins[p]==h
            pins[p]=h
    for mode in ('canonical','func'):
        receipt=load(root/(mode+'-r1.driver.json')); done=load(root/(mode+'-r1.driver-closed.json'))
        assert done['pins_unchanged'] and done['native_exit']==(int(vc['canonical_gate_native_exit']!=0) if mode=='canonical' else 0)
        pins.update(receipt['pins'])
    pins.update(load(ft/'inputs.json'))
    for row in lc['rows']: pins.update(row['artifacts'])
    assert all(sha(p)==h for p,h in pins.items())
    assert [(q['name'],q['result']) for q in lc['queries']]==[
        ('data-owner-equivalence','unsat'),('fetch-exclusion-required','sat')]
    assert [(r['name'],r['build_exit'],r['native_exit']) for r in lc['rows']]==[
        ('positive',0,0),('data-width-lost',0,1),('fetch-bus-width-lost',0,1),('object-override-lost',0,1)]
    assert 'DATA-SIZE-OK checks=362144 data=352910 fetch-differences=650 objects=173128' in lc['rows'][0]['log']
    parent=Path(cs['parent']); source=parent/'candidate'
    names=sorted(str(p.relative_to(source)) for p in source.rglob('*') if p.is_file())
    assert len(names)==195 and cs['changes']==[recipe.FILE]
    for name in names:
        before=(source/name).read_bytes()
        expected=recipe.transform(before.decode()).encode() if name==recipe.FILE else before
        assert (core/'candidate'/name).read_bytes()==expected
    assert sha(core/'obj/tb_ventium')==cc['binary_sha256']==fs['model']
    native=(core/'obj/Vventium_top__verFiles.dat').read_text()
    assert native.count('-GAXI_LINE_REPLAY=0')==1
    assert set(re.findall(r'\+define\+(\w+)',native))==set(cs['definitions']) and len(cs['definitions'])==152
    host=Path(cs['host']); assert (core/'obj'/(host.stem+'.o')).is_file()
    deps=(core/'obj'/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
    headers=[Path(s) for s in deps if Path(s).name=='Vventium_top___024root.h']
    assert len(headers)==1
    assert (headers[0] if headers[0].is_absolute() else core/'obj'/headers[0]).resolve()==(core/'obj/Vventium_top___024root.h').resolve()
    goldens={}
    for p in (func/'private-enabled-cache').glob('*.vtrace'):
        t=tracefmt.read_trace(str(p)); name=re.search(r'elf=(\w+)\.func\.elf ',t.hdr['note']).group(1)
        assert name not in goldens; goldens[name]=p
    assert len(goldens)==108
    records=paired=0; raw_fail=[]
    for job,row in zip(fs['jobs'],fc['rows']):
        name=job[1]; assert row['name']==name and row['passed'] and row['actual_wait']
        assert row['error'] is None and row['native_worker_exit']==0 and row['affinity_verified']
        cpu=int(row['command'][2])
        assert {v['executable'] for v in row['observed_affinity'].values()}=={'tb_ventium','qemu-i386'}
        assert all(v['affinity']==[cpu] for v in row['observed_affinity'].values())
        rtl=func/'work'/(name+'.func_rtl.vtrace'); gold=goldens[name]
        r,g=tracefmt.read_trace(str(rtl)),tracefmt.read_trace(str(gold))
        assert len(r.records)==len(g.records) and r.x87==g.x87==bool(int(job[6]))
        records+=len(r.records); manifest=load(Path(job[2]).parent/'manifest.json'); options=[]
        def fmt(v): return f'{v[0]}:{"" if len(v)<2 or v[1] is None else v[1]}'+(f'={v[2]}' if len(v)>=3 and v[2] else '')
        for key,mask in (('x87_fprem1_cc_ranges','0x4300'),('x87_stkflt_fstat_ranges','0x4741')):
            if manifest.get(key):
                options+=['--mask-fstat-exc',mask]
                for v in manifest[key]: options+=['--mask-fstat-range',fmt(v)]
        for v in manifest.get('x87_stkflt_fpr_ranges',[]): options+=['--mask-fpr-range',fmt(v)]
        if not options and manifest.get('x87_stkflt_arch'): options+=['--mask-fstat-exc','0x4741','--mask-x87-fpr']
        assert equivalent(gold,rtl,options)
        if not equivalent(gold,rtl): raw_fail.append(name)
        log=(func/'work'/(name+'.func_rtl.log')).read_text(); assert '--l1-axi selected' in log
        paired+=int(re.search(r'pairedV=(\d+)',log).group(1))
    assert records==80800 and paired==30134
    controls=parent.parent/'complete-r3'
    for path in sorted((core/'generic-work').glob('*.cycle_rtl.vtrace')):
        control=controls/(path.name.replace('.cycle_rtl.vtrace','-lat7.vtrace'))
        assert tracefmt.read_trace(str(path)).records==tracefmt.read_trace(str(control)).records
    assert len(vc['deltas'])==20 and all(r['same_records'] for r in vc['deltas'])
    result=load(ft/'summary.json')
    assert result['result']=='PASS' and result['inputs_stable'] and result['full_case_set']
    assert result['backend']==dict(name='l1-axi',axi_latency=7)
    assert len(result['results'])==22
    for row in result['results']:
        case=row['case']; assert row['result']=='PASS' and not row['errors']
        folder=ft/f"case{case}-{fetch.CASES[case]['name']}"; mode=folder/'cycle-func'
        symbols=fetch.contracts.symbols(folder/'image.elf'); bios=(folder/'image.bin').read_bytes()
        fetch.validate_image(case,symbols,bios)
        receipt=load(mode/'rtl.receipt.json'); assert receipt['actual_return_code']==133
        trace=fetch.contracts.read_complete_trace(mode/'rtl.vtrace')
        fetch.grade_native(case,trace,(mode/'rtl.stdout').read_text(),(mode/'rtl.stderr').read_text(),symbols,bios,133)
        assert equivalent(folder/'qemu.vtrace',mode/'rtl.vtrace')
    assert all(sha(p)==h for p,h in pins.items())
    artifacts={str(p):sha(p) for directory in (func,ft) for p in directory.rglob('*') if p.is_file()}
    for p in (Path(__file__),core/'build-started.json',core/'build-closed.json',core/'verify-started.json',
              core/'verify-closed.json',leaf/'closed.json'):
        artifacts[str(p)]=sha(p)
    checked=dict(audit_passed=True,owners=owners,pins_checked=len(pins),source_files=195,
        changes=[recipe.FILE],functional_passes=108,unmasked_functional_passes=108-len(raw_fail),
        unmasked_failures=raw_fail,functional_records=records,v_retirements=paired,fetch_boundary_cases=22,
        cycle_traces_unchanged=20,canonical_gate_native_exit=vc['canonical_gate_native_exit'],
        canonical_gate_passed=vc['canonical_gate_passed'],standard_suite=False,hardware_acceptance=False,
        gameplay_ipc=None,fmax_mhz=None,artifacts=artifacts)
    with (root/'audit.json').open('x') as f: json.dump(checked,f,indent=2)
    print(json.dumps({k:v for k,v in checked.items() if k!='artifacts'},indent=2))


if __name__=='__main__': main()
