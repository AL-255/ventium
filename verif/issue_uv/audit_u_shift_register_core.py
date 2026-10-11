#!/usr/bin/env python3
"""Independently reopen the register-shift core's complete regression streams.

This does not convert a red canonical gate into a pass or qualify the FPGA.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
from prepare_u_shift_registers import transform

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import compare
import tracefmt


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def load(p): return json.loads(p.read_text())


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for n in ('root','parent'):
        parser.add_argument('--'+n,type=Path,required=True)
    args=parser.parse_args()
    root,parent=args.root.resolve(strict=True),args.parent.resolve(strict=True)
    assert __debug__ and root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    core=root/'core-r1'
    started,built=load(core/'build-started.json'),load(core/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    models=dict(control=parent/'obj/tb_ventium',candidate=core/'obj/tb_ventium')
    assert sha(models['candidate'])==built['binary_sha256']=='ce54833f54ad48e002ad001b0eb7223ac81e910f5aca8400a04634babf948fa0'
    assert sha(models['control'])==started['parent_model']=='1c9cc9ede4e2afe92d9b85333949f8a4ed5927757d6c309edfa0a370e33b7f29'
    files=sorted(str(p.relative_to(core/'candidate')) for p in (core/'candidate').rglob('*') if p.is_file())
    assert files==sorted(str(p.relative_to(parent/'candidate')) for p in (parent/'candidate').rglob('*') if p.is_file())
    assert [p for p in files if sha(core/'candidate'/p)!=sha(parent/'candidate'/p)]==started['changes']==['rtl/core/core.sv']
    assert (core/'candidate/rtl/core/core.sv').read_text()==transform((parent/'candidate/rtl/core/core.sv').read_text())
    checks=load(root/'queue/closed.json')
    assert checks['directed_passed'] and checks['pins_unchanged'] and not checks['errors']
    assert checks['all_20_cycle_streams_identical'] and checks['all_108_functional_streams_identical']
    pins={**started['pins'],**load(root/'queue/started.json')['pins']}
    for owner in checks['owners']:
        state=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',owner['unit'],
            '-pMainPID','-pSubState','-pInvocationID','-pExecMainStatus'],text=True).splitlines())
        assert {k:v for k,v in owner.items() if k!='unit'}==state and state['MainPID']=='0'
    system=root/'system-r1'
    info,done=load(system/'started.json'),load(system/'closed.json')
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert len(info['cases'])==64 and len(done['measurements'])==256 and info['cycle_mode']==1 and not info['debug_step']
    pins.update(info['pins'])
    arch=cycles=paired=0
    for case,reloc,offset in info['cases']:
        folder=system/f'c{case}-r{reloc}-o{offset}'
        golden=tracefmt.read_trace(str(folder/'golden.vtrace'))
        symbols=load(folder/'symbols.json')
        assert golden.sys and not golden.x87 and golden.mode=='func'
        assert 100<len(golden.records)<2000 and int(golden.records[-1]['eax'],0)&255==0x42
        for latency in (0,7):
            both={}
            for name,model in models.items():
                streams={}
                for mode in ('cycle-func','cycle'):
                    stem=f'{name}-lat{latency}-{mode}'
                    command=load(folder/(stem+'.command.json'))
                    assert str(model) in command and '--'+mode in command and '--l1-axi' in command
                    assert load(folder/(stem+'.exit.json'))['native_exit']==133
                    trace=tracefmt.read_trace(str(folder/(stem+'.vtrace')))
                    assert len(trace.records)==len(golden.records)
                    assert [r['n'] for r in trace.records]==list(range(len(trace.records)))
                    assert [r['pc'] for r in trace.records]==[r['pc'] for r in golden.records]
                    if mode=='cycle-func':
                        assert compare.compare_func(golden,trace,False,0xffffffff,False,20,io.StringIO(),sys_both=True)==0
                        arch+=len(trace.records)
                    else:
                        assert trace.mode=='cycle' and not trace.sys and not trace.x87
                        cycles+=len(trace.records)
                        witnessed=0
                        for i,row in enumerate(trace.records):
                            if int(row['pc'],0)==symbols['shift_subject']:
                                v=trace.records[i+1]
                                assert int(v['pc'],0)==symbols['shift_branch']
                                witnessed+=int(row['pipe']=='U' and v['pipe']=='V' and v['paired'] and row['cyc']==v['cyc'])
                        if case<6 and offset<=15: assert witnessed==8
                        paired+=witnessed
                    streams[mode]=trace.records
                both[name]=streams
            assert both['control']==both['candidate']
    assert (arch,cycles,paired)==(33280,33280,1792)
    verify=load(core/'verify-closed.json')
    assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
    assert len(verify['deltas'])==20 and all(r['same_records'] for r in verify['deltas'])
    for row in verify['deltas']:
        assert tracefmt.read_trace(str(core/'generic-work'/row['name'])).records==tracefmt.read_trace(str(parent/'generic-work'/row['name'])).records
    replay=root/'canonical-same-input'
    before,closed=load(replay/'started.json'),load(replay/'closed.json')
    assert closed['same_input_regression_passed'] and closed['pins_unchanged'] and not closed['errors']
    assert len(closed['rows'])==len(before['cases'])==108 and closed['records']==80800
    pins.update(before['pins'])
    n=0
    for case in before['cases']:
        folder=replay/case['name']
        records={}
        for name,model in models.items():
            command=load(folder/(name+'-command.json'))
            assert command[0]==str(model) and command[-2:]==['--cycle-func','--l1-axi']
            assert load(folder/(name+'-exit.json'))['native_exit']==0
            records[name]=tracefmt.read_trace(str(folder/(name+'.vtrace'))).records
        original=tracefmt.read_trace(case['original']).records
        assert original==records['control']==records['candidate']
        n+=len(original)
    assert n==80800
    for folder in (system,replay,root/'queue'):
        pins.update({str(p):sha(p) for p in folder.rglob('*') if p.is_file()})
    for p in (Path(__file__),Path(__file__).with_name('prepare_u_shift_registers.py'),
              core/'build-started.json',core/'build-closed.json',core/'verify-started.json',core/'verify-closed.json'):
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(audit_complete=True,directed_regressions_passed=True,model_sha256=built['binary_sha256'],
        cold_fixtures=64,architectural_records=arch,cycle_records=cycles,paired_subjects=paired,
        all_20_canonical_cycle_streams_identical=True,same_input_canonical_cases=108,
        same_input_canonical_records=n,canonical_gate_passed=verify['canonical_gate_passed'],
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,timing_mhz=None,pins=pins)
    with (root/'core-audit.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)


if __name__=='__main__': main()
