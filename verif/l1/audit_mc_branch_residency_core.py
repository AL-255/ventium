#!/usr/bin/env python3
"""Audit branch-ownership core traces without changing the canonical gate."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(REPO/'verif/diff'),str(REPO/'verif/sys')]
import compare
import tracefmt
from build_mc_branch_residency_core import HEADER, PARENT_MODEL
from prepare_mc_branch_residency import transform


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def load(p):
    return json.loads(Path(p).read_text())


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('root','parent'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    root,parent=args.root.resolve(strict=True),args.parent.resolve(strict=True)
    assert __debug__ and root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    core=root/'core-r1'
    started,built=load(core/'build-started.json'),load(core/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    models=dict(control=parent/'obj/tb_ventium',candidate=core/'obj/tb_ventium')
    assert sha(models['control'])==started['parent_model']==PARENT_MODEL
    assert sha(models['candidate'])==built['binary_sha256']
    actual=sorted(str(p.relative_to(core/'candidate')) for p in (core/'candidate').rglob('*')
        if p.is_file() and sha(p)!=sha(parent/'candidate'/p.relative_to(core/'candidate')))
    assert actual==started['changes']==[HEADER]
    assert (core/'candidate'/HEADER).read_text()==transform((parent/'candidate'/HEADER).read_text())
    pins=started['pins'].copy()
    assert all(sha(p)==h for p,h in pins.items())
    owners=[]

    def owner(unit,inv,code=0):
        p=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
            '-pInvocationID','-pMainPID','-pSubState','-pExecMainStatus'],text=True).splitlines())
        assert p==dict(InvocationID=inv,MainPID='0',SubState='exited' if code==0 else 'failed',
                       ExecMainStatus=str(code)),(unit,p)
        owners.append(dict(unit=unit,**p))

    owner('ventium-mc-branch-residency-core-oct11.service','916fb46387e24fd48a1e5610c57ec738')
    assert built['binary_sha256']=='70900101369189169e472a78f7c4ca8ca34dbb99d6f45c0df5115d505b6a4a3e'
    profiles=[]
    for model in models.values():
        stamp=model.parent/'Vventium_top__verFiles.dat'
        command=next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
        defs=set(re.findall(r'\+define\+(\w+)',command))
        assert ' --assert ' in command and not {'SYNTHESIS','VTM_NO_DPI','VEN_SYS_FASTPATH_ALL'} & defs
        assert {'VEN_L1_AXI','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_FE_PIPE',
                'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_RAW_V_READ_PRIME'} <= defs
        profiles.append(defs)
        pins.update({str(p):sha(p) for p in (model,stamp)})
    assert profiles[0]==profiles[1] and len(profiles[0])==150
    counts={}
    for label,cases in [('branch',640),('held',24),('memory',72),('fp',72),('agi',12)]:
        folder=root/(label+'-r1')
        done=load(folder/('result.json' if label=='held' else 'closed.json'))
        assert done['passed'] and not done['errors']
        if label=='held':
            assert done['inputs_unchanged'] and len(done['cases'])==48
            inputs=load(folder/'inputs.json')
            inv=done['invocation']
            leaves=sorted(folder.glob('k*-r*-o*'))
        else:
            assert done['pins_unchanged'] and len(done['measurements'])==cases*4
            info=load(folder/'started.json');inputs=info['pins'];inv=info['invocation']
            leaves=sorted(p.parent for p in folder.glob('*/closed.json'))
        assert len(leaves)==cases
        pins.update(inputs)
        owner('ventium-mc-branch-residency-'+label+'-oct11.service',inv)
        count=dict(fixtures=cases,architectural_records=0,cycle_records=0,paired_v=0)
        for path in leaves:
            gold=tracefmt.read_trace(str(path/'golden.vtrace'))
            assert gold.mode=='func' and gold.sys and gold.x87==(label in ('fp','agi'))
            assert 100<len(gold.records)<(5000 if label=='held' else 2000)
            assert int(gold.records[-1]['eax'],0)&255==0x42
            for latency in (0,7):
                records={}
                for name,model in models.items():
                    clocks=[]
                    for mode in ('cycle-func','cycle'):
                        stem=f'{name}-'+('l' if label=='held' else 'lat')+str(latency)+'-'+mode
                        command=load(path/(stem+'.command.json'))
                        assert str(model) in command and '--'+mode in command
                        assert {'--system','--cosim','--l1-axi'}<=set(command)
                        assert command[command.index('--max-insn')+1]==('5000' if label=='held' else '2000')
                        rc=int((path/(stem+'.exit')).read_text()) if label=='held' else load(path/(stem+'.exit.json'))['native_exit']
                        assert rc==133
                        text=(path/(stem+'.stdout')).read_text()+'\n'+(path/(stem+'.stderr')).read_text()
                        assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL',text)
                        trace=tracefmt.read_trace(str(path/(stem+'.vtrace')))
                        rows=trace.records
                        assert [r['n'] for r in rows]==list(range(len(gold.records)))
                        assert [r['pc'] for r in rows]==[r['pc'] for r in gold.records]
                        footer=re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) after (\d+) retired in (\d+) clocks$',text,re.M)
                        assert len(footer)==1 and int(footer[0][0])==len(rows)
                        clocks.append(int(footer[0][1]))
                        records[name,mode]=rows
                        if mode=='cycle-func':
                            assert trace.sys and trace.x87==gold.x87
                            assert all(all(k in r for k in tracefmt.SYS_CR) for r in rows)
                            stream=io.StringIO()
                            assert compare.compare_func(gold,trace,False,0xffffffff,False,20,stream,sys_both=True)==0,stream.getvalue()
                            if name=='candidate':count['architectural_records']+=len(rows)
                        elif name=='candidate':
                            count['cycle_records']+=len(rows)
                            count['paired_v']+=sum(r.get('pipe')=='V' and bool(r.get('paired')) for r in rows)
                    assert clocks[0]==clocks[1],(label,path,'observation changed cycles')
                for mode in ('cycle-func','cycle'):
                    assert records['control',mode]==records['candidate',mode],(label,path,latency,mode)
        assert count['paired_v']>0
        counts[label]=count
        pins.update({str(p):sha(p) for p in folder.rglob('*') if p.is_file()})
    verify,vstart=load(core/'verify-closed.json'),load(core/'verify-started.json')
    assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
    assert verify['canonical_gate_native_exit'] in (0,2)
    assert verify['canonical_gate_passed']==(verify['canonical_gate_native_exit']==0)
    owner('ventium-mc-branch-residency-verify-oct11.service',vstart['invocation'],0 if verify['canonical_gate_passed'] else 1)
    pins.update(vstart['pins'])
    cycles=sorted((core/'generic-work').glob('*.cycle_rtl.vtrace'))
    assert len(cycles)==20
    for path in cycles:
        old=parent/'generic-work'/path.name
        assert tracefmt.read_trace(str(path)).records==tracefmt.read_trace(str(old)).records
        pins.update({str(p):sha(p) for p in (path,old)})
    faults=load(root/'faults-r1/closed.json')
    fault_start=load(root/'faults-r1/started.json')
    assert faults['passed'] and faults['pins_unchanged'] and not faults['errors']
    assert len(faults['measurements'])==32
    # The fault driver runs in a guarded scope; its controller has a distinct
    # InvocationID. Use the retained outer owner, not an invented equality.
    checks=load(root/'checks/closed.json')
    assert checks['directed_passed'] and checks['pins_unchanged'] and not checks['errors']
    fault_owner=next(r for r in checks['owners'] if r['label']=='faults')
    owner(fault_owner['unit'],fault_owner['InvocationID'])
    pins.update(fault_start['pins'])
    pins.update({str(root/'faults-r1'/p):h for p,h in faults['artifacts'].items()})
    replay=root/'canonical-same-input'
    replay_start,replayed=load(replay/'started.json'),load(replay/'closed.json')
    assert replayed['same_input_regression_passed'] and replayed['pins_unchanged'] and not replayed['errors']
    assert len(replayed['rows'])==len(replay_start['cases'])==108
    assert replayed['records']==80800
    pins.update(replay_start['pins'])
    replay_records=0
    for case in replay_start['cases']:
        folder=replay/case['name']
        traces={}
        for label,model in models.items():
            command=load(folder/(label+'-command.json'))
            assert command[0]==str(model) and command[-2:]==['--cycle-func','--l1-axi']
            assert command[command.index('--init-esp')+1]==case['esp']
            assert command[command.index('--image')+1]==case['image']
            assert command[command.index('--max-insn')+1]==case['maxinsn']
            assert load(folder/(label+'-exit.json'))['native_exit']==0
            traces[label]=tracefmt.read_trace(str(folder/(label+'.vtrace')))
            assert traces[label].mode=='func' and traces[label].x87==case['x87']
        original=tracefmt.read_trace(case['original'])
        assert traces['control'].records==traces['candidate'].records==original.records
        replay_records+=len(original.records)
    assert replay_records==80800
    pins.update({str(p):sha(p) for p in replay.rglob('*') if p.is_file()})
    for p in (Path(__file__),Path(__file__).with_name('build_mc_branch_residency_core.py'),
              Path(__file__).with_name('prepare_mc_branch_residency.py'),
              core/'build-started.json',core/'build-closed.json',core/'verify-started.json',
              core/'verify-closed.json',root/'faults-r1/closed.json',root/'checks/closed.json'):
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(audit_complete=True,directed_regressions_passed=True,pins=pins,owners=owners,
        counts=counts,model_sha256=built['binary_sha256'],all_20_canonical_cycle_streams_identical=True,
        canonical_gate_passed=verify['canonical_gate_passed'],gameplay_ipc=None,
        same_input_canonical_cases=108,same_input_canonical_records=replay_records,focused_fault_cases=16,
        full_fault_permission_sweep=False,standard_suite=False,hardware_acceptance=False,timing_mhz=None)
    with (root/'core-audit.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','owners')},indent=2))


if __name__=='__main__':main()

