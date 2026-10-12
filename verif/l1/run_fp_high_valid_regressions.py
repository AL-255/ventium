"""Run unchanged whole-core regressions after the wide-valid FP matrix closes.

One guarded owner, sequential suites, bounded native fan-out; no synthesis,
route, deployment, trace filtering, golden changes or failure waivers.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

from build_fp_high_valid_core import MODEL as PARENT_MODEL
from test_fp_high_valid_cofactor import sha

REPO=Path(__file__).resolve().parents[2]
MODEL='ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c'


def plan(parent, candidate, root):
    control,model=parent/'obj/tb_ventium',candidate/'obj/tb_ventium'
    probe=REPO/'verif/fetchguard/run_probe_core_corpus.py'
    common=['--control',str(control),'--candidate',str(model)]
    rows=[]
    for offset in (0,1,24,25,29,4093):
        rows.append((f'boundary-{offset}',probe,
            ['--suite','fp',*common,'--workers','8','--kind','1','--offset','0','--offset','31',
             '--operand-offset',str(offset)],120))
    rows += [
        ('faults',REPO/'verif/l1/run_fp_read_ack_faults.py',
         # The fixed-port QEMU gate serializes 32 native runs. The first
         # attempt completed 22 at 7.9 s/run before this outer cap expired.
         # Keep its per-run 90 s watchdog and all comparisons unchanged.
         ['--parent',str(parent),'--candidate',str(candidate)],420),
        ('integer',probe,['--suite','integer',*common,'--workers','8'],180),
        ('memory',REPO/'verif/l1/run_l1_capture_cut_system.py',common,120),
        ('held',REPO/'verif/l1/run_mc_address_held.py',common,120),
        ('branch',REPO/'verif/l1/run_mc_address_branch.py',[*common,'--workers','4'],420),
        ('replay',REPO/'verif/l1/run_load_read_ack_core.py',
         ['--suite','canonical','--parent',str(parent),'--candidate',str(candidate)],240),
    ]
    return [(label,['/usr/bin/python3','-B',str(script),*args,'--out',str(root/label)],cap)
            for label,script,args,cap in rows]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for key in ('parent','candidate','fp','out'): ap.add_argument('--'+key,type=Path,required=True)
    args=ap.parse_args()
    parent,candidate,fp=[getattr(args,k).resolve(strict=True) for k in ('parent','candidate','fp')]
    root=args.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert scratch.stat().st_dev!=REPO.stat().st_dev
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    pins={str(Path(__file__).resolve()):sha(__file__)}
    load=lambda p:json.loads(p.read_text())
    for folder,digest in ((parent,PARENT_MODEL),(candidate,MODEL)):
        built=load(folder/'build-closed.json'); before=load(folder/'build-started.json')
        assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
        assert sha(folder/'obj/tb_ventium')==built['binary_sha256']==digest
        pins.update(before['pins'])
        for p in (folder/'build-closed.json',folder/'build-started.json',folder/'obj/tb_ventium'):
            pins[str(p)]=sha(p)
    done,before=load(fp/'closed.json'),load(fp/'started.json')
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert len(done['measurements'])==1536 and len(done['deltas'])==768
    assert before['models']['candidate']==str(candidate/'obj/tb_ventium')
    assert all(r['saved_clocks']==0 for r in done['deltas'])
    pins.update(before['pins'])
    verified=load(candidate/'verify-closed.json')
    assert verified['pins_unchanged'] and verified['canonical_gate_native_exit'] in (0,2)
    assert all(r['same_records'] for r in verified['deltas'])
    assert not verified['masks_or_goldens_or_bands_changed']
    for p in (fp/'started.json',fp/'closed.json',candidate/'verify-closed.json'):
        pins[str(p)]=sha(p)
    commands=plan(parent,candidate,root)
    for _,cmd,_ in commands: pins[cmd[2]]=sha(cmd[2])
    assert all(sha(p)==h for p,h in pins.items())
    assert shutil.disk_usage(scratch).free>5*1024**3
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as stream: json.dump(value,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],commands=commands,
         affinity=sorted(os.sched_getaffinity(0))))
    begin=time.monotonic(); result=dict(passed=False,rows=[],errors=[],gameplay_ipc=None,
        standard_suite=False,hardware_acceptance=False,canonical_gate_passed=verified['canonical_gate_passed'])
    try:
        for label,command,cap in commands:
            assert shutil.disk_usage(scratch).free>4*1024**3, 'external live disk floor'
            start=time.monotonic()
            with (root/(label+'.log')).open('x') as stream:
                child=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,
                    pass_fds=(9,),timeout=cap)
            row=dict(label=label,native_exit=child.returncode,seconds=time.monotonic()-start)
            result['rows'].append(row); save(label+'-exit.json',row)
            assert child.returncode==0,(label,child.returncode)
            receipt=root/label/('result.json' if label=='held' else 'closed.json')
            checked=load(receipt)
            passed='same_input_regression_passed' if label=='replay' else 'passed'
            stable='inputs_unchanged' if label=='held' else 'pins_unchanged'
            assert checked[passed] and checked[stable] and not checked['errors'],label
            row['receipt_sha256']=sha(receipt)
            print(json.dumps(row),flush=True)
        result['passed']=True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result); print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
