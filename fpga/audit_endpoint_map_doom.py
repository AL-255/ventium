"""Read-only closure/stall audit; native exit zero is not Doom acceptance."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def observations(text):
    done = re.findall(r'^>>> done: cyc=(\d+) retires=(\d+) last cs=([0-9a-f]+):eip=([0-9a-f]+)$',text,re.M)
    stalls = re.findall(r'^\[STALL\] no retire for (\d+) cyc: state=(\d+) cs=([0-9a-f]+):eip=([0-9a-f]+)',text,re.M)
    perf = re.findall(r'^\[VEN-PERF\] cycle=(\d+) retires=(\d+) clocks=(\d+) u=(\d+) v=(\d+)',text,re.M)
    result = dict(stall_messages=len(stalls),longest_no_retire_cycles=max((int(r[0]) for r in stalls),default=0),
                  guest_accepted=False,gameplay_ipc=None,fps=None)
    if done:
        assert len(done)==1
        cycle,count,cs,eip=done[0]
        result.update(final_cycle=int(cycle),final_retire_count=int(count),final_cs=cs,final_eip=eip)
    if stalls:
        result['last_stall']=dict(no_retire_cycles=int(stalls[-1][0]),state=int(stalls[-1][1]),
                                  cs=stalls[-1][2],eip=stalls[-1][3])
    if perf:
        end=tuple(map(int,perf[-1]))
        result['final_u'],result['final_v']=end[3:]
        same=[tuple(map(int,r)) for r in perf if int(r[1])==end[1]]
        result['sampled_no_retire_window']=[same[0][0],end[0]]
    return result


def audit(root,unit):
    started=json.loads((root/'started.json').read_text())
    closed=json.loads((root/'closed.json').read_text())
    owner=dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',unit,'-p','SubState','-p','MainPID',
        '-p','ExecMainStatus','-p','InvocationID'],text=True).splitlines())
    assert owner==dict(SubState='exited',MainPID='0',ExecMainStatus='0',InvocationID=started['invocation'])
    assert started['unit']==unit and started['cold_reset'] and started['diagnostic_only']
    assert closed['native_exit']==0 and closed['child_reaped'] and closed['inputs_unchanged']
    assert not closed['reason'] and not closed['failure']
    assert not closed['standard_suite'] and not closed['hardware_acceptance']
    assert closed['gameplay_ipc'] is None and closed['fps'] is None
    assert all(closed['memory_events'][k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    assert closed['guest_executable_and_wad_unchanged'] and closed['demo_log_native_exit']==0
    assert all(sha(p)==h for p,h in started['pins'].items())
    assert all(sha(root/p)==h for p,h in closed['artifacts'].items())
    native=json.loads((root/'native.json').read_text())
    assert native['argv']==started['argv'] and native['affinity']==[12]
    assert sha(native['exe'])==started['model']
    result=observations((root/'run.log').read_text())
    assert result['final_cycle']==started['max_cycles']
    result.update(diagnostic_closed=True,owner=owner,input_pins=len(started['pins']),
                  artifacts=len(closed['artifacts']),closed_sha256=sha(root/'closed.json'),
                  demo_log_bytes=(root/'DEMO3.LOG').stat().st_size,no_oom=True)
    return result


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run',type=Path,required=True)
    ap.add_argument('--unit',required=True)
    args=ap.parse_args()
    print(json.dumps(audit(args.run.resolve(strict=True),args.unit),indent=2))
