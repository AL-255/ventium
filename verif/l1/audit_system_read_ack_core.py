"""Independently replay closed ACK/system evidence; never award suite/FPGA pass."""
import argparse
import json
from pathlib import Path
import re
import subprocess

import build_system_read_ack_core as builder
import run_system_read_ack_core as run


def owner(unit,invocation,code):
    props=dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show',unit,'-p','MainPID','-p','InvocationID',
        '-p','ExecMainStatus','-p','Result'],text=True,timeout=10).splitlines())
    assert props['MainPID']=='0' and props['InvocationID']==invocation
    assert props['ExecMainStatus']==str(code) and props['Result']==('success' if code==0 else 'exit-code')
    return props


def audit(root):
    core=root/'system-read-ack-core-r1'
    parent=root/'raw-prime-storage-core-r1'
    leaf=root/'system-read-ack-leaf-r2'
    pins=builder.check_leaf(leaf)
    started=json.loads((core/'build-started.json').read_text())
    built=json.loads((core/'build-closed.json').read_text())
    assert built['passed'] and built['native_exit']==0 and built['pins_unchanged']
    assert run.sha(core/'obj/tb_ventium')==built['binary_sha256']==run.MODEL
    pins.update(started['pins'])
    for name in run.recipe.PARENTS:
        assert (core/'candidate'/run.recipe.PREFIX/name).read_text()==run.recipe.transform(
            (parent/'candidate'/run.recipe.PREFIX/name).read_text(),name)
    owners={}
    owners['build']=owner('ventium-system-read-ack-core-oct16-r1.service','af1f4b17ddbd419e8b1fbf4e6f4facdf',0)
    states=set(); phases=set(); totals=dict(cases=0,trace_pairs=0,functional_records=0,cycle_records=0,v_retirements=0,native_children=0)
    for folder,unit,names in (
        (root/'system-read-ack-system-r1','ventium-system-read-ack-system-oct16-r1.service',run.CASES),
        (root/'system-read-ack-extra-r2','ventium-system-read-ack-extra-oct16-r2.service',['plar','ptaskpg','pcalltss','nested-rm'])):
        start,closed=[json.loads((folder/n).read_text()) for n in ('started.json','closed.json')]
        owners[folder.name]=owner(unit,start['invocation'],0)
        assert closed['passed'] and not closed['errors'] and closed['pins_unchanged']
        assert start['models']==dict(parent=run.PARENT,candidate=run.MODEL)
        assert all(closed['memory_events'][k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
        pins.update(start['pins'])
        for case in names:
            casepath=folder/case
            gold=run.tracefmt.read_trace(str(casepath/'gold.vtrace'))
            manifest=run.REPO/'verif/sys/tests'/case/'manifest.json'
            if case=='nested-rm': manifest=Path(__file__).with_name('system_read_ack_rm_fixed')/'manifest.json'
            m=json.loads(manifest.read_text())
            totals['cases']+=1
            for delay in (0,7,31):
                for mode in ('cycle-func','cycle'):
                    traces={}
                    for label in ('parent','candidate'):
                        name=f'{label}-{delay}-{mode}'
                        native=json.loads((casepath/(name+'.native.json')).read_text())
                        assert native['actual_wait'] and native['group_closed'] and native['actual_return_code']==m['exit_code']
                        assert not native['timed_out'] and not native['cleanup_errors'] and not native['descendant_leak']
                        assert not native['signals_after_reap'] and native['native_affinity_observed']
                        argv=native['argv']
                        assert '--'+mode in argv and '--l1-axi' in argv and '--system' in argv and '--cosim' in argv
                        assert f'AXI_RLAT={delay}' in argv and f'AXI_WLAT={delay}' in argv
                        assert native['native_affinity']==[int(argv[2])]
                        assert Path(native['native_executable'])==(core if label=='candidate' else parent)/'obj/tb_ventium'
                        assert not Path('/proc',str(native['process_group'])).exists()
                        for stream in ('stdout','stderr'):
                            assert run.sha(casepath/(name+'.'+stream))==native[stream+'_sha256']
                        stdout=(casepath/(name+'.stdout')).read_text(); stderr=(casepath/(name+'.stderr')).read_text()
                        assert not run.native.FATAL.search(stdout+stderr)
                        trace=run.tracefmt.read_trace(str(casepath/(name+'.vtrace')))
                        traces[label]=trace.records
                        if mode=='cycle-func':
                            run.native.grade_native(trace,stdout,stderr,m['exit_code'],m['exit_code'],m['max_insn'])
                            import io
                            assert run.compare.compare_func(gold,trace,False,0xffffffff,False,20,io.StringIO(),sys_both=True)==0
                        if label=='candidate':
                            totals['functional_records' if mode=='cycle-func' else 'cycle_records']+=len(trace.records)
                            if mode=='cycle': totals['v_retirements']+=sum(r.get('pipe')=='V' and r.get('paired',False) for r in trace.records)
                            for state,phase in re.findall(r'\[SYSTEM-READ-ACK\] state=(\w+) walk=(\d+)',stdout):
                                states.add(state)
                                if state=='S_WALK':phases.add(int(phase))
                        totals['native_children']+=1
                    assert traces['parent']==traces['candidate']
                    totals['trace_pairs']+=1
        for p in folder.rglob('*'):
            if p.is_file():pins[str(p)]=run.sha(p)
    assert set(run.recipe.STATES)<=states and phases=={0,2}
    assert totals['cases']==19 and totals['trace_pairs']==114 and totals['native_children']==228
    assert totals['v_retirements']==5925 and totals['functional_records']==totals['cycle_records']
    # Original canonical verdict stays authoritative, including all failures.
    verify=json.loads((core/'verify-closed.json').read_text())
    vst=json.loads((core/'verify-started.json').read_text())
    pins.update(vst['pins'])
    owners['canonical']=owner('ventium-system-read-ack-verify-oct16-r1.service',vst['invocation'],
                               0 if verify['canonical_gate_native_exit']==0 else 1)
    assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
    assert len(verify['deltas'])==20 and all(r['same_records'] for r in verify['deltas'])
    for p in (Path(__file__),Path(builder.__file__),Path(run.__file__),core/'build-started.json',
              core/'build-closed.json',core/'verify-started.json',core/'verify-closed.json'):
        pins[str(p.resolve())]=run.sha(p)
    assert all(run.sha(p)==h for p,h in pins.items())
    return dict(directed_passed=True,models=dict(parent=run.PARENT,candidate=run.MODEL),
        source_changes=builder.CHANGES,owners=owners,counts=totals,read_states_exercised=list(run.recipe.STATES),
        walk_read_phases=sorted(phases),pins=pins,canonical_gate_passed=verify['canonical_gate_passed'],
        canonical_gate_native_exit=verify['canonical_gate_native_exit'],canonical_cycle_parent_identical=True,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    a=ap.parse_args(); root=a.root.resolve(strict=True)
    assert root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    report=audit(root)
    run.save(root/'system-read-ack-audit-r1.json',report)
    print(json.dumps({k:v for k,v in report.items() if k!='pins'},indent=2))
