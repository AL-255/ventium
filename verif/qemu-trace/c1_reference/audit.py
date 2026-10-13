"""Recheck closed private-reference work and triangulate the remaining RTL fault."""
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
import run_probe

REPO=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(REPO/'verif/diff'))
import compare
import tracefmt


def load(p):
    return json.loads(p.read_text())


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    a=ap.parse_args(); root=a.root.resolve(strict=True)
    assert __debug__ and os.sched_getaffinity(0)=={12}
    assert not (root/'audit.json').exists()
    owners={}; pins={}
    for label, expected in (('build',0),('probe',0),('func',1)):
        folder=root/(label+'-r1'); started=load(folder/'started.json'); closed=load(folder/'closed.json')
        command=['systemctl','--user','show','ventium-qemu-c1-'+label+'-oct13-r1.service']
        for key in ('MainPID','SubState','ExecMainStatus','InvocationID','MemoryPeak',
                    'ExecMainStartTimestampMonotonic','ExecMainExitTimestampMonotonic'):
            command+=['-p',key]
        owner=dict(line.split('=',1) for line in subprocess.check_output(command,text=True).splitlines())
        assert owner['MainPID']=='0' and owner['SubState']==('exited' if expected==0 else 'failed')
        assert int(owner['ExecMainStatus'])==expected and closed['pins_unchanged']
        if label=='build':
            events=[json.loads(line) for line in subprocess.check_output(['journalctl','--user',
                '--no-pager','-o','json','USER_INVOCATION_ID='+started['invocation']],text=True).splitlines()]
            starts=[e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and e.get('JOB_TYPE')=='start']
            stops=[e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and 'MEMORY_PEAK' in e]
            assert len(starts)==len(stops)==1 and starts[0]['JOB_RESULT']=='done'
            assert str(root.name) in starts[0]['MESSAGE']
            assert int(owner['ExecMainStartTimestampMonotonic']) <= int(starts[0]['__MONOTONIC_TIMESTAMP']) < int(stops[0]['__MONOTONIC_TIMESTAMP']) <= int(owner['ExecMainExitTimestampMonotonic'])
            owner.update(scope_invocation=started['invocation'],scope_memory_peak=stops[0]['MEMORY_PEAK'],
                         scope_swap_peak=stops[0].get('MEMORY_SWAP_PEAK'))
        else:
            assert owner['InvocationID']==started['invocation']
        for path,digest in started['pins'].items():
            assert path not in pins or pins[path]==digest
            pins[path]=digest
        owners[label]=owner
    build=root/'build-r1'; bs=load(build/'started.json'); bc=load(build/'closed.json')
    source=load(build/'source.json'); parent=Path(bs['parent'])
    assert bc['passed'] and source['changed']==sorted(set(prepare.rounding.PARENTS)|{prepare.HELPER})
    derived=prepare.transform({n:(parent/n).read_text() for n in source['changed']})
    for name,digest in source['after'].items():
        assert sha(build/'source'/name)==digest
        if name in derived:
            assert (build/'source'/name).read_text()==derived[name]
        else:
            assert digest==source['before'][name]
    assert sha(bc['binary'])==bc['sha256']
    probe=root/'probe-r1'; pc=load(probe/'closed.json')
    cases=load(probe/'cases.json')
    expected=run_probe.cases()
    assert json.loads(json.dumps(expected))==cases and len(cases)==34200 and pc['passed']
    values={name:list(struct.iter_unpack('<4I',(probe/(name+'.bin')).read_bytes()))
            for name in ('control','candidate','native')}
    for row in pc['rows']:
        assert sha(probe/(row['label']+'.bin'))==row['stdout_sha256']
        assert len(values[row['label']])==row['records']==34200 and row['native_exit']==0
    for index,case in enumerate(cases):
        old=values['control'][index]
        for name in ('candidate','native'):
            value=values[name][index]
            target=case['expected']<<9 if case['mask']==0x200 else case['expected']
            assert value[3]&case['mask']==target
            assert value[:3]==old[:3]
        assert not ((values['candidate'][index][3]^old[3])&~case['mask'])
    func=root/'func-r1'; fc=load(func/'closed.json'); fs=load(func/'started.json')
    assert len(fc['rows'])==108 and sum(r['passed'] for r in fc['rows'])==107
    assert [r['name'] for r in fc['rows'] if not r['passed']]==['tx_regform']
    assert fc['memory_events']['oom']==fc['memory_events']['oom_kill']=='0'
    goldens={}
    for p in (func/'private-enabled-cache').glob('*.vtrace'):
        t=tracefmt.read_trace(str(p))
        name=re.search(r'elf=(\w+)\.func\.elf ',t.hdr['note']).group(1)
        assert name not in goldens
        goldens[name]=p
    assert len(goldens)==108
    records=paired=unmasked=0
    for job,row in zip(fs['jobs'],fc['rows']):
        name=job[1]; assert row['name']==name and row['actual_wait'] and row['error'] is None
        assert row['native_worker_exit']==0 and row['affinity_verified']
        cpu=int(row['command'][2])
        assert {r['executable'] for r in row['observed_affinity'].values()}=={'tb_ventium','qemu-i386'}
        assert all(r['affinity']==[cpu] for r in row['observed_affinity'].values())
        rtl=func/'work'/(name+'.func_rtl.vtrace')
        r,g=tracefmt.read_trace(str(rtl)),tracefmt.read_trace(str(goldens[name]))
        assert len(r.records)==len(g.records) and r.x87==g.x87==bool(int(job[6]))
        records+=len(r.records)
        manifest=load(Path(job[2]).parent/'manifest.json')
        args=['--mode','func']
        def fmt(v):
            return f'{v[0]}:{"" if len(v)<2 or v[1] is None else v[1]}'+(f'={v[2]}' if len(v)>=3 and v[2] else '')
        for key,mask in (('x87_fprem1_cc_ranges','0x4300'),('x87_stkflt_fstat_ranges','0x4741')):
            if manifest.get(key):
                args+=['--mask-fstat-exc',mask]
                for v in manifest[key]: args+=['--mask-fstat-range',fmt(v)]
        for v in manifest.get('x87_stkflt_fpr_ranges',[]): args+=['--mask-fpr-range',fmt(v)]
        if len(args)==2 and manifest.get('x87_stkflt_arch'):
            args+=['--mask-fstat-exc','0x4741','--mask-x87-fpr']
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            rc=compare.main([*args,str(goldens[name]),str(rtl)])
            raw=compare.main(['--mode','func',str(goldens[name]),str(rtl)])
        assert rc==int(name=='tx_regform')
        unmasked+=raw==0
        if name=='tx_fprem': assert raw==0
        log=(func/'work'/(name+'.func_rtl.log')).read_text()
        assert '--l1-axi selected' in log
        pair=re.search(r'pairedV=(\d+)',log)
        assert pair
        paired+=int(pair[1])
    assert records==80800 and paired>0
    observer=Path('/home/yukidama/external/tmp/ventium-preexit-gpr-native.14cUSbOf/native_gpr')
    assert sha(observer)=='32fe78eeaea8ad1aee68d23f278fa89d739631a11d45688858f9524bd132960d'
    command=[str(observer),str(func/'work/tx_regform.func.elf'),'0x0804801d','1']
    native=subprocess.run(command,capture_output=True,timeout=15)
    assert native.returncode==0 and not native.stderr
    witness=json.loads(native.stdout)
    assert witness['native_exit']==0 and witness['child_reaped']
    assert witness['instruction_prefix'].startswith('d9fc')
    r=tracefmt.read_trace(str(func/'work/tx_regform.func_rtl.vtrace')).records
    g=tracefmt.read_trace(str(goldens['tx_regform'])).records
    assert witness['before']['fctrl']==r[14]['fctrl']==g[14]['fctrl']=='0x037f'
    assert int(witness['before']['st'][0],16)==int(r[14]['st0'],16)==int(g[14]['st0'],16)
    exact=run_probe.rounding.exact_value(0x3fff,0xcc4ab916fefc719e)
    assert 3*exact.denominator < 2*exact.numerator < 4*exact.denominator
    assert witness['after']['st'][0]=='40008000000000000000'
    assert witness['after']['fstat']==g[15]['fstat']=='0x0220' and r[15]['fstat']=='0x0020'
    assert all(sha(p)==h for p,h in pins.items())
    artifacts={str(p.relative_to(root)):sha(p) for folder in (probe,func) for p in folder.rglob('*') if p.is_file()}
    result=dict(audit_passed=True,owners=owners,rehashed_pins=len(pins),source_files=len(source['after']),
        probe_cases=34200,probe_numerics_unchanged=True,probe_unrelated_status_unchanged=True,
        functional_passes=107,functional_failures=['tx_regform'],unmasked_passes=unmasked,
        tx_fprem_unmasked_pass=True,complete_records=records,v_retirements=paired,
        remaining_frndint_witness=witness,native_command=command,artifacts=artifacts,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (root/'audit.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('artifacts','remaining_frndint_witness')},indent=2))


if __name__=='__main__':
    main()
