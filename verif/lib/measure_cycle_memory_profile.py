"""Measure external AXI-wait sensitivity without changing RTL or gate bands.

Replay all twenty closed canonical cycle images at added waits 0 and 7, in
cycle and full architectural formats. Keep every native result and original
metric verdict. This is diagnosis, not a standard-suite or FPGA pass.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

REPO=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(REPO/'verif'),str(REPO/'verif/diff')]
import m5_metrics
import tracefmt


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def load(p): return json.loads(p.read_text())


def save(p,data):
    with p.open('x') as f: json.dump(data,f,indent=2)


def counts(log):
    match=re.search(r'tb: retired (\d+) instructions in (\d+) clocks',log)
    assert match, 'missing actual retirement totals'
    result=dict(records=int(match[1]),clocks=int(match[2]))
    backing=re.search(r'\[L1DPERF\] fill cycles=(\d+) backing-wait=(\d+) backing-ack=(\d+)',log)
    assert backing and int(backing[3])>0, 'AXI backend not exercised'
    result.update(fill_cycles=int(backing[1]),backing_wait=int(backing[2]),backing_ack=int(backing[3]))
    pair=re.search(r'retires\s+\d+\s+\(U=(\d+)\s+pairedV=(\d+)\)',log)
    assert pair
    result.update(u=int(pair[1]),v=int(pair[2]))
    assert result['u']+result['v']==result['records']
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core',required=True,type=Path)
    ap.add_argument('--out',required=True,type=Path)
    args=ap.parse_args()
    core=args.core.resolve(strict=True); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert core.is_relative_to(scratch) and root.is_relative_to(scratch) and not root.exists()
    assert os.sched_getaffinity(0)=={13} and os.environ['INVOCATION_ID']
    assert scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(root.parent).free>4*1024**3+128*1024**2
    built=load(core/'build-closed.json'); model=core/'obj/tb_ventium'
    assert built['passed'] and built['native_exit']==0 and built['pins_unchanged']
    assert sha(model)==built['binary_sha256']
    defs=load(core/'build-started.json')['definitions']
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC'}<=set(defs)
    assert not {'VEN_SYS_FASTPATH_ALL','VEN_HALF_CACHE','HALF_CACHE'} & set(defs)
    old=core/'generic-work'
    manifests=sorted(old.glob('*.cycle.result'))
    assert len(manifests)==20
    pins={str(p):sha(p) for p in (model,core/'build-started.json',core/'build-closed.json',
        core/'verify-closed.json',Path(__file__),Path(m5_metrics.__file__),
        REPO/'verif/m4_metrics.py',Path(tracefmt.__file__),REPO/'verif/diff/compare.py')}
    jobs=[]
    for path in manifests:
        result=path.read_text().strip().split('|')
        assert result[0]=='CYCLE' and result[3]=='1'
        name=result[1]; golden=Path(result[5])
        argv=(old/(name+'.cycle_rtl.argv')).read_bytes().split(b'\0')
        assert argv.pop()==b''
        argv=[s.decode() for s in argv]
        assert argv[0]==str(model) and argv.count('--cycle')==1 and '--l1-axi' in argv
        assert not {'--dbg-step','--dbg-bp','--no-trace'} & set(argv)
        image=Path(argv[argv.index('--image')+1])
        for p in (path,golden,image,old/(name+'.cycle_rtl.argv'),
                  old/(name+'.cycle_rtl.vtrace'),old/(name+'.cycle_rtl.log')):
            pins[str(p)]=sha(p)
        jobs.append((name,argv,golden))
    root.mkdir()
    base={k:v for k,v in os.environ.items() if not k.startswith(('AXI_','VEN_','VENTIUM_','TB_'))}
    base.update(TMPDIR=str(root),PYTHONDONTWRITEBYTECODE='1')
    start=time.monotonic()
    save(root/'started.json',dict(model_sha256=sha(model),pins=pins,definitions=defs,
        invocation=os.environ['INVOCATION_ID'],affinity=[13],modes=['cycle','cycle-func'],
        added_waits=[0,7],canonical_gate=False,standard_suite=False,gameplay_ipc=None))
    rows=[]; errors=[]
    try:
        for name,template,golden in jobs:
            observations={}
            for latency in (0,7):
                for mode in ('cycle','cycle-func'):
                    assert time.monotonic()-start<450
                    assert shutil.disk_usage(root).free>4*1024**3
                    tag=f'{name}.lat{latency}.{mode}'; trace=root/(tag+'.vtrace')
                    command=list(template)
                    command[command.index('--cycle')]='--'+mode
                    command[command.index('--out')+1]=str(trace)
                    env=dict(base,AXI_RLAT=str(latency),AXI_WLAT=str(latency))
                    before=time.monotonic(); observed=False
                    with (root/(tag+'.log')).open('x') as log:
                        child=subprocess.Popen(command,env=env,cwd=REPO,stdout=log,
                            stderr=subprocess.STDOUT,start_new_session=True)
                        try:
                            while child.poll() is None:
                                if time.monotonic()-before>60: raise TimeoutError(tag)
                                try:
                                    if (Path('/proc')/str(child.pid)/'exe').resolve()==model:
                                        assert os.sched_getaffinity(child.pid)=={13}
                                        observed=True
                                except (FileNotFoundError,ProcessLookupError): pass
                                time.sleep(.001)
                            code=child.wait()
                        finally:
                            if child.poll() is None:
                                os.killpg(child.pid,signal.SIGTERM)
                                try: child.wait(timeout=5)
                                except subprocess.TimeoutExpired:
                                    os.killpg(child.pid,signal.SIGKILL);child.wait()
                    native=dict(argv=command,environment={'AXI_RLAT':str(latency),'AXI_WLAT':str(latency)},
                        exit=code,actual_wait=True,affinity_observed=observed,affinity=[13],
                        pid=child.pid,proc_gone=not (Path('/proc')/str(child.pid)).exists(),
                        seconds=time.monotonic()-before)
                    save(root/(tag+'.native.json'),native)
                    assert code==0 and observed and native['proc_gone'],native
                    log=(root/(tag+'.log')).read_text()
                    assert '--l1-axi selected' in log
                    assert not re.search(r'Assertion failed|%Error|%Fatal|CPU HUNG|UNIMPLEMENTED',log)
                    recs=tracefmt.read_trace(str(trace)).records
                    stat=counts(log)
                    assert len(recs)==stat['records'] and [r['n'] for r in recs]==list(range(len(recs)))
                    observations[latency,mode]=(recs,stat)
            for latency in (0,7):
                cycle,cstat=observations[latency,'cycle']
                func,fstat=observations[latency,'cycle-func']
                assert [r['pc'] for r in cycle]==[r['pc'] for r in func]
                assert cstat==fstat and cycle[-1]['cyc']==cstat['clocks']
            assert observations[0,'cycle-func'][0]==observations[7,'cycle-func'][0],name+' architectural change'
            prior=tracefmt.read_trace(str(old/(name+'.cycle_rtl.vtrace'))).records
            assert observations[7,'cycle'][0]==prior,name+' latency7 repeat drift'
            assert observations[7,'cycle'][1]==counts((old/(name+'.cycle_rtl.log')).read_text())
            row=dict(name=name,latency0=observations[0,'cycle'][1],latency7=observations[7,'cycle'][1],
                full_architecture_equal=True,latency7_canonical_repeat_identical=True,golden=str(golden))
            rows.append(row)
            print(json.dumps(row),flush=True)
        # Reuse the original metric code, tolerance and FP relation, unchanged.
        for latency in (0,7):
            chain=next(r for r in rows if r['name']=='mb_faddchain')[f'latency{latency}']
            os.environ['M5_FADDCHAIN_CPI']=str(chain['clocks']/chain['records'])
            for row in rows:
                trace=root/f"{row['name']}.lat{latency}.cycle.vtrace"
                row[f'metrics{latency}']=m5_metrics.compute(row['name'],str(trace),row['golden'],10)
    except Exception as exc:
        import traceback
        errors.append(dict(error=repr(exc),traceback=traceback.format_exc()))
    cg=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    events=dict(s.split() for s in (cg/'memory.events').read_text().splitlines())
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(diagnostic_completed=not errors and len(rows)==20 and stable,rows=rows,errors=errors,
        pins_unchanged=stable,seconds=time.monotonic()-start,memory_events=events,
        canonical_gate_passed=False,standard_suite=False,physical_board=False,gameplay_ipc=None)
    result['diagnostic_completed'] &= all(events[k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    save(root/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return int(not result['diagnostic_completed'])


if __name__=='__main__': raise SystemExit(main())
