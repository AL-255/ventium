"""Recover this closed native gate from the guard's durable exit-status marker.

The outer controller timed out while its guarded job completed normally later.
Preserve that timeout, prove the native family is gone, and never rerun it or
infer an exit code from log wording. No golden, trace or acceptance alteration.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

from build_prime_reg_flags_core import sha,load,save,stable
from run_prime_reg_flags_core import PARENT,CANDIDATE

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','candidate'):ap.add_argument('--'+name,required=True,type=Path)
    args=ap.parse_args()
    parent,core=args.parent.resolve(strict=True),args.candidate.resolve(strict=True)
    before=load(core/'verify-started.json')
    assert before['invocation']=='f353943b60a145ccb9e41958b425d1a2'
    assert not (core/'verify-closed.json').exists()
    assert sha(core/'obj/tb_ventium')==CANDIDATE and sha(parent/'obj/tb_ventium')==PARENT
    pins=dict(before['pins']);assert stable(pins)
    unit='ventium-build-1000-481480-12982.scope'
    marker=Path('/tmp/ventium-build-scope/ventium-build-1000-481480-12982.5OrK5p')
    assert (marker/'unit').read_text().strip()==unit.removesuffix('.scope')
    assert (marker/'result').read_text()=='2\n'
    state=dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',unit,'-p','ActiveState','-p','SubState','-p','ControlGroup'],text=True).splitlines())
    assert state==dict(ActiveState='inactive',SubState='dead',ControlGroup='')
    controller='ventium-prime-reg-verify-oct13-r1.service'
    owner=dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',controller,'-p','InvocationID','-p','MainPID','-p','ExecMainStatus'],text=True).splitlines())
    assert owner==dict(InvocationID=before['invocation'],MainPID='0',ExecMainStatus='1')
    journal=subprocess.check_output(['journalctl','--user','-u',controller,'--no-pager'],text=True)
    assert 'subprocess.TimeoutExpired' in journal and 'timed out after 660 seconds' in journal
    native_journal=subprocess.check_output(['journalctl','--user','-u',unit,'--no-pager'],text=True)
    assert str(marker/'result') in native_journal and '600s make verify' in native_journal
    assert 'Consumed' in native_journal
    jobs=[line.split('\t') for line in (core/'generic-work/jobs.txt').read_text().splitlines()]
    assert len(jobs)==128 and sum(row[0]=='func' for row in jobs)==108
    totals={'PASS':0,'FAIL':0}
    for row in jobs:
        mode,name=row[:2];path=core/'generic-work'/(name+'.'+mode+'.result')
        result=path.read_text().strip().split('|')
        assert result[:2]==[mode.upper(),name]
        if mode=='func':totals[result[3]]+=1
        pins[str(path)]=sha(path)
    assert totals==dict(PASS=7,FAIL=101)
    log=(core/'generic.log').read_text()
    assert 'func totals: 7 PASS / 101 FAIL / 108 total' in log
    assert 'VERIFY GATE: FAIL' in log and log.rstrip().endswith('make: *** [Makefile:465: verify] Error 1')
    old=sorted((parent/'generic-work').glob('*.cycle_rtl.vtrace'))
    new=sorted((core/'generic-work').glob('*.cycle_rtl.vtrace'))
    assert len(old)==len(new)==20 and [p.name for p in old]==[p.name for p in new]
    deltas=[]
    for a,b in zip(old,new):
        x,y=tracefmt.read_trace(str(a)),tracefmt.read_trace(str(b))
        assert x.records==y.records
        deltas.append(dict(name=b.name,same_records=True,records=len(y.records)))
        for p in (a,b):pins[str(p)]=sha(p)
    evidence=core/'verify-recovery';evidence.mkdir()
    for name in ('unit','started','result'):shutil.copyfile(marker/name,evidence/name)
    (evidence/'controller-journal.txt').write_text(journal)
    (evidence/'native-journal.txt').write_text(native_journal)
    for path in (Path(__file__).resolve(),core/'verify-started.json',core/'generic.log',
                 core/'generic-work/jobs.txt',*evidence.iterdir()):pins[str(path)]=sha(path)
    assert stable(pins)
    save(core/'verify-closed.json',dict(canonical_gate_native_exit=2,canonical_gate_passed=False,
         controller_timed_out=True,controller_native_exit=1,recovered_from_native_marker=True,
         native_scope=unit,native_scope_state=state,controller_owner=owner,pins_unchanged=True,
         deltas=deltas,functional_results=totals,standard_suite=False,gameplay_ipc=None,
         masks_or_goldens_or_bands_changed=False,recovery_pins=pins))
    print('Recovered native exit 2 / FAIL; outer timeout retained; 20 identical cycle traces',flush=True)


if __name__=='__main__':
    assert __debug__
    main()
