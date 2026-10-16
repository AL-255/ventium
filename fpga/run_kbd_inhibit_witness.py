"""Reproduce lost-byte ready on the frozen FPGA keyboard injector, no fix yet."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
REPO=Path(__file__).resolve().parents[1]
INJECTOR=ROOT/'sfetch-boundary-fpga-r1/flow/src/ven_ps2_kbd_inject.v'
INJECTOR_SHA='3fee16426277e11292ab018346e28c31c99de0e2f38d9f23b4c9443d6ef719c8'


def sha(p):
    with Path(p).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--out',type=Path,required=True)
    a=parser.parse_args();out=a.out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    assert ROOT.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(ROOT).free>4*1024**3
    assert out.parent.resolve(strict=True)==ROOT and not out.exists()
    assert sorted(os.sched_getaffinity(0))==[12,13] and os.environ.get('INVOCATION_ID')
    cg=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((cg/'memory.max').read_text())<=512*1024**2
    assert (cg/'memory.swap.max').read_text().strip()=='0'
    assert 0<int((cg/'pids.max').read_text())<=32
    assert sha(INJECTOR)==INJECTOR_SHA
    files=[INJECTOR,REPO/'fpga/tb_kbd_inhibit.sv']
    pins={str(p):sha(p) for p in [*files,Path(__file__).resolve()]}
    out.mkdir();(out/'source').mkdir()
    for p in files:
        dest=out/'source'/p.name;shutil.copyfile(p,dest);assert sha(dest)==pins[str(p)]
        pins[str(dest)]=sha(dest)
    native={n:str(Path(shutil.which(n)).resolve(strict=True)) for n in ('iverilog','vvp')}
    pins.update({p:sha(p) for p in native.values()})
    def save(n,v):
        with (out/n).open('x') as stream:json.dump(v,stream,indent=2)
    cases=[(hz,phase) for hz in (3125000,40000000) for phase in range(23)]
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cases=cases,
        parent_only=True,correctness=False,physical_fpga=False,gameplay_ipc=None))
    begin=time.monotonic();rows=[];builds=[];errors=[]
    def execute(case):
        hz,phase=case;label=f'{hz}-p{phase}';log=out/(label+'.log')
        cmd=[native['vvp'],str(out/f'{hz}.vvp'),f'+phase={phase}']
        with log.open('x') as stream:
            child=subprocess.Popen(cmd,stdout=stream,stderr=subprocess.STDOUT)
            try:
                affinity=sorted(os.sched_getaffinity(child.pid));assert affinity==[12,13]
                code=child.wait(timeout=12)
            except BaseException:child.kill();child.wait();raise
        text=log.read_text()
        good=(code==1 and f'KBD-EARLY-READY-WHILE-INHIBITED hz={hz} phase={phase}' in text)
        if phase>=21:good=code==0 and f'KBD-INHIBIT-OK hz={hz} phase={phase} retry=0 reset_cancel=1' in text
        row=dict(hz=hz,phase=phase,passed=good,native_exit=code,native_pid=child.pid,
            waited=True,affinity=affinity,command=cmd,expected_red=phase<21,
            log=str(log),log_sha256=sha(log),image_sha256=sha(cmd[1]))
        print(json.dumps({k:row[k] for k in ('hz','phase','passed','native_exit')}),flush=True)
        return row
    try:
        for hz in (3125000,40000000):
            cmd=[native['iverilog'],'-g2012','-Wall','-s','tb_kbd_inhibit',
                f'-Ptb_kbd_inhibit.HZ={hz}','-o',str(out/f'{hz}.vvp'),
                *[str(out/'source'/p.name) for p in files]]
            with (out/f'{hz}-compile.log').open('x') as stream:
                p=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,timeout=30)
            builds.append(dict(command=cmd,native_exit=p.returncode));assert p.returncode==0
        with ThreadPoolExecutor(max_workers=2) as pool:
            for row in pool.map(execute,cases):
                rows.append(row)
                if not row['passed']:errors.append([row['hz'],row['phase']])
    except Exception as exc:errors.append(repr(exc))
    stable=all(sha(p)==h for p,h in pins.items())
    events={k:int(v) for k,v in (s.split() for s in (cg/'memory.events').read_text().splitlines())}
    good=not errors and stable and len(rows)==46 and not any(events[k] for k in ('oom','oom_kill','oom_group_kill'))
    result=dict(witness_matrix_passed=good,correctness=False,rows=rows,builds=builds,errors=errors,
        pins_unchanged=stable,memory_events=events,memory_peak=int((cg/'memory.peak').read_text()),
        seconds=time.monotonic()-begin,physical_fpga=False,standard_suite=False,gameplay_ipc=None)
    save('closed.json',result);print(json.dumps({k:v for k,v in result.items() if k not in ('rows','builds')}),flush=True)
    return 0 if good else 1


if __name__=='__main__':raise SystemExit(main())
