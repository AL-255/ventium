#!/usr/bin/env python3
"""Run the unchanged cold matrices on the branch-ownership model; no waivers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

REPO = Path(__file__).resolve().parents[2]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def props(unit):
    return dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
        '-pMainPID','-pSubState','-pInvocationID','-pExecMainStatus'],text=True,timeout=10).splitlines())


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ('root','parent'):
        parser.add_argument('--'+key,type=Path,required=True)
    args=parser.parse_args()
    root,parent=args.root.resolve(strict=True),args.parent.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert shutil.disk_usage(scratch).free>5*1024**3
    core=root/'core-r1'
    built=json.loads((core/'build-closed.json').read_text())
    started=json.loads((core/'build-started.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']
    assert sha(parent/'obj/tb_ventium')==started['parent_model']
    assert started['changes']==['rtl/core/core_mem_chain.svh']
    pins=started['pins'].copy()
    pins[str(Path(__file__))]=sha(__file__)
    canonical_ab=REPO/'verif/l1/run_canonical_same_input_ab.py'
    pins[str(canonical_ab)]=sha(canonical_ab)
    assert all(sha(p)==h for p,h in pins.items())
    work=root/'checks'
    work.mkdir()
    def save(name,value):
        with (work/name).open('x') as stream:
            json.dump(value,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID']))
    result=dict(directed_passed=False,canonical_gate_passed=False,errors=[],owners=[],
                gameplay_ipc=None,standard_suite=False,hardware_acceptance=False)
    helper=scratch/'ventium-fp-exec-cut.MNkzxfBO'
    both=['--control',str(parent/'obj/tb_ventium'),'--candidate',str(core/'obj/tb_ventium')]
    offsets=[x for value in (0,1,7,15,30,31) for x in ('--offset',str(value))]
    jobs=[
        ('branch',REPO/'verif/l1/run_mc_address_branch.py',[],900),
        ('held',REPO/'verif/l1/run_mc_address_held.py',[],300),
        ('memory',REPO/'verif/l1/run_l1_capture_cut_system.py',[],300),
        ('fp',helper/'system/run_same_profile_fp.py',['--workers','12',*offsets],300),
        ('agi',helper/'agi-r1/run_agi_same_profile.py',['--workers','4','--kind','0',*offsets],300),
    ] # 4 +8 +4 +12 +4 =32 test workers; all native children bounded to CPUs 8-31.
    active={}

    def launch(label,args,seconds,tmpdir=scratch):
        unit='ventium-mc-branch-residency-'+label+'-oct11.service'
        command=['systemd-run','--user','--unit='+unit,'--remain-after-exit',
            '--property=MemoryMax=3G','--property=MemorySwapMax=0','--property=TasksMax=2048',
            '--property=RuntimeMaxSec='+str(seconds),'--property=TimeoutStopSec=30',
            '--property=KillMode=control-group','--setenv=TMPDIR='+str(tmpdir),
            '--setenv=PYTHONDONTWRITEBYTECODE=1',
            '--setenv=VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator',
            '/usr/bin/taskset','-c','8-31',*map(str,args)]
        save(label+'-command.json',command)
        with (work/(label+'-launch.log')).open('x') as log:
            subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=30)
        state=props(unit)
        assert state['InvocationID']
        active[label]=(unit,state['InvocationID'],time.monotonic()+seconds+45)

    def wait_all(allow_fail=False):
        while active:
            if shutil.disk_usage(scratch).free<4*1024**3:
                for unit,inv,_ in active.values():
                    assert props(unit)['InvocationID']==inv
                    subprocess.run(['systemctl','--user','stop',unit],check=True,timeout=60)
                raise RuntimeError('owned checks stopped at 4 GiB disk reserve')
            for label,(unit,inv,deadline) in list(active.items()):
                state=props(unit)
                assert state['InvocationID']==inv,('owner changed',unit,state)
                if state['MainPID']=='0' and state['SubState'] in ('failed','exited'):
                    result['owners'].append(dict(label=label,unit=unit,**state))
                    del active[label]
                    if not allow_fail and (state['SubState']!='exited' or state['ExecMainStatus']!='0'):
                        result['errors'].append(dict(label=label,owner=state))
                else:
                    assert time.monotonic()<deadline,('observation timeout; do not restart',unit,state)
            if active:
                time.sleep(2)
    try:
        for label,script,extra,seconds in jobs:
            pins[str(script)]=sha(script)
            launch(label,['/usr/bin/python3','-B',script,*both,'--out',root/(label+'-r1'),*extra],seconds)
        wait_all()
        assert not result['errors']
        for label,count in [('branch',640),('held',24),('memory',72),('fp',72),('agi',12)]:
            receipt=root/(label+'-r1')/('result.json' if label=='held' else 'closed.json')
            done=json.loads(receipt.read_text())
            assert done['passed'] and not done['errors']
            assert done['inputs_unchanged' if label=='held' else 'pins_unchanged']
            assert len(done['cases' if label=='held' else 'measurements'])==count*(2 if label=='held' else 4)
        launch('faults',[REPO/'tools/build_scope.sh','--','/usr/bin/python3','-B',
            REPO/'verif/l1/run_fp_read_ack_faults.py','--parent',parent,'--candidate',core,
            '--out',root/'faults-r1'],600)
        wait_all()
        assert not result['errors']
        faults=json.loads((root/'faults-r1/closed.json').read_text())
        assert faults['passed'] and faults['pins_unchanged'] and not faults['errors']
        result['directed_passed']=True
        launch('verify',['/usr/bin/python3','-B',REPO/'verif/issue_uv/run_fp_nomem_verify.py',
            '--parent',parent,'--core',core],900,tmpdir=core)
        wait_all(allow_fail=True)
        gate=json.loads((core/'verify-closed.json').read_text())
        assert gate['pins_unchanged'] and not gate['masks_or_goldens_or_bands_changed']
        assert len(gate['deltas'])==20 and all(r['same_records'] for r in gate['deltas'])
        result.update(canonical_gate_passed=gate['canonical_gate_passed'],
            canonical_native_exit=gate['canonical_gate_native_exit'],all_20_cycle_streams_identical=True)
        command=['/usr/bin/python3','-B',str(canonical_ab),'--parent',str(parent),
            '--candidate',str(core),'--out',str(root/'canonical-same-input')]
        save('canonical-ab-command.json',command)
        with (work/'canonical-ab.log').open('x') as log:
            subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
        result['all_108_functional_streams_identical']=True
    except Exception as error:
        import traceback
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
    save('closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if result['directed_passed'] and result['canonical_gate_passed'] and result['pins_unchanged'] and not result['errors'] else 1


if __name__=='__main__':
    raise SystemExit(main())
