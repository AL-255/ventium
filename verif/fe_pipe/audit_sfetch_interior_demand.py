"""Require full A/B cycle/state identity beyond the original demand grader."""
from collections import defaultdict
import json
from pathlib import Path
import subprocess
import sys

import run_sfetch_interior_cofactor as leaf
import run_sfetch_interior_func as candidate

sys.path.insert(0,str(candidate.REPO/'verif/diff'))
import tracefmt

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


def main():
    root=ROOT/'sfetch-interior-demand-r1'
    def load(p):return json.loads(p.read_text())
    start,done=load(root/'started.json'),load(root/'closed.json')
    assert __debug__ and done['passed'] and done['pins_unchanged'] and not done['errors']
    assert done['clean_resources'] and done['all_children_reaped']
    assert len(start['cases'])==48 and len(done['measurements'])==192
    assert start['workers']==32 and start['cache_policy']=='enabled' and start['scenario']=='demand'
    assert all(leaf.sha(p)==h for p,h in start['pins'].items())
    assert leaf.sha(start['models']['candidate'])==candidate.MODEL
    assert leaf.sha(start['models']['control'])==candidate.PARENT
    props=dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show','ventium-sfetch-interior-demand-oct16-r1.service',
        '-p','InvocationID','-p','SubState','-p','MainPID','-p','Result','-p','ExecMainStatus'],
        text=True,timeout=10).splitlines())
    assert props==dict(InvocationID='64ac56cac3e7471eabe6a39f71065484',SubState='exited',
                       MainPID='0',Result='success',ExecMainStatus='0')
    groups=defaultdict(dict)
    for row in done['measurements']:
        key=(*row['case'],row['latency'])
        assert row['model'] not in groups[key]
        groups[key][row['model']]={k:v for k,v in row.items() if k!='model'}
    assert len(groups)==96
    assert all(set(pair)=={'control','candidate'} and pair['control']==pair['candidate'] for pair in groups.values())
    records=0;v_retirements=0;streams=0;artifacts={}
    for case in start['cases']:
        m,k,p,o,t=case;work=root/f'm{m}-k{k}-p{p}-o{o}-t{t}'
        assert load(work/'closed.json')['passed']
        for latency in (0,7):
            for mode in ('cycle-func','cycle'):
                traces=[]
                for model in ('control','candidate'):
                    stem=f'{model}-lat{latency}-{mode}'
                    assert load(work/(stem+'.exit.json'))['native_exit']==133
                    traces.append(tracefmt.read_trace(str(work/(stem+'.vtrace'))).records)
                assert traces[0]==traces[1] and traces[1],(case,latency,mode)
                streams+=1
                if mode=='cycle':
                    records+=len(traces[1])
                    v_retirements+=sum(r.get('pipe')=='V' and r.get('paired') for r in traces[1])
        for p in work.iterdir():
            if p.is_file():artifacts[str(p)]=leaf.sha(p)
    before,after=load(root/'resources-before.json'),load(root/'resources-after.json')
    assert set(before['cgroup.procs'].split())==set(after['cgroup.procs'].split())
    assert before['pids.events']==after['pids.events']
    events=dict(s.split() for s in after['memory.events'].splitlines())
    assert all(events[k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    for p in (root/'started.json',root/'closed.json',root/'resources-before.json',root/'resources-after.json',
              Path(__file__),Path(leaf.__file__),Path(candidate.__file__),Path(tracefmt.__file__)):
        artifacts[str(p.resolve())]=leaf.sha(p)
    result=dict(passed=True,owner=props,scope_invocation=start['invocation'],source_pins=len(start['pins']),
                identical_stream_pairs=streams,measurements=192,candidate_cycle_records=records,
                actual_v_retirements=v_retirements,cycle_delta_percent=0,
                memory_peak=int(after['memory.peak']),artifacts=artifacts,model=candidate.MODEL,
                canonical_gate_passed=False,standard_suite=False,physical_fpga=False,gameplay_ipc=None)
    assert all(leaf.sha(p)==h for p,h in artifacts.items())
    with (root/'cycle-audit.json').open('x') as stream:json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'},indent=2))


if __name__=='__main__':main()
