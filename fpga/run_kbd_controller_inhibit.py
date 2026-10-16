"""Bounded public-port integration of the retained 8042 and FPGA injector.

The original endpoint supplies explicit red witnesses. No FPGA export is
changed; the controller and endpoint candidates remain separately pinned.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import prepare_kbd_inhibit as recipe
import run_kbd_inhibit_witness as witness

ROOT=witness.ROOT
REPO=witness.REPO
sha=witness.sha
CONTROLLER=ROOT/'ps2-loss-aux-transport-r1/source/candidate.v'
CONTROLLER_SHA='9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405'
FIFO=CONTROLLER.with_name('simple_fifo.v')
FIFO_SHA='aff3ebc275191351eb582f2624cb056712d392331a951f1ed778360ca81f3bf4'
FIXED=ROOT/'kbd-inhibit-candidate-r1/ven_ps2_kbd_inject.v'
FIXED_SHA='b0dff672729c1658249bd50359204c5ee79498d8b7b0cdef60dadd6526ae88bf'


def cases():
    return [('candidate',hz,phase,reset) for hz,phase,reset in
            itertools.product((3125000,40000000),range(26),(0,1))]+[
                ('parent',hz,20,0) for hz in (3125000,40000000)]


def grade(case,code,text):
    label,hz,phase,reset=case
    if label=='parent':
        return code==1 and f'KBD-CONTROLLER-EARLY-READY hz={hz} phase={phase}' in text and 'KBD-CONTROLLER-OK' not in text
    retry=int(not reset and (phase<21 or phase in (23,24)))
    expected=f'KBD-CONTROLLER-OK hz={hz} phase={phase} reset={reset} retry={retry} irq1=1'
    return code==0 and text.splitlines()[0]==expected and 'FATAL' not in text


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();out=args.out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    assert out.parent.resolve(strict=True)==ROOT and not out.exists()
    assert ROOT.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(ROOT).free>4*1024**3
    assert sorted(os.sched_getaffinity(0))==[12,13] and os.environ.get('INVOCATION_ID')
    cg=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((cg/'memory.max').read_text())<=512*1024**2
    assert (cg/'memory.swap.max').read_text().strip()=='0' and 0<int((cg/'pids.max').read_text())<=32
    for path,digest in ((CONTROLLER,CONTROLLER_SHA),(FIFO,FIFO_SHA),(FIXED,FIXED_SHA),
                        (witness.INJECTOR,witness.INJECTOR_SHA)):
        assert sha(path)==digest,path
    assert FIXED.read_text()==recipe.transform(witness.INJECTOR.read_text())
    files={'controller.v':CONTROLLER,'simple_fifo.v':FIFO,'parent.v':witness.INJECTOR,
           'candidate.v':FIXED,'tb_kbd_controller_inhibit.sv':REPO/'fpga/tb_kbd_controller_inhibit.sv'}
    pins={str(p):sha(p) for p in [*files.values(),Path(__file__).resolve(),
                                Path(recipe.__file__).resolve(),Path(witness.__file__).resolve()]}
    out.mkdir();src=out/'source';src.mkdir()
    for name,path in files.items():
        shutil.copyfile(path,src/name);assert sha(src/name)==pins[str(path)]
        pins[str(src/name)]=sha(src/name)
    native={n:str(Path(shutil.which(n)).resolve(strict=True)) for n in ('iverilog','vvp')}
    pins.update({p:sha(p) for p in native.values()})
    def save(name,obj):
        with (out/name).open('x') as stream:json.dump(obj,stream,indent=2)
    selected=cases()
    save('started.json',dict(invocation=os.environ['INVOCATION_ID'],pins=pins,cases=selected,
        definitions=['VEN_KBC_FAST','VEN_KBD_AUTOACK'],physical_fpga=False,standard_suite=False,gameplay_ipc=None))
    begin=time.monotonic();builds=[];rows=[];errors=[]
    def execute(case):
        label,hz,phase,reset=case
        assert time.monotonic()-begin<500
        log=out/f'{label}-{hz}-p{phase}-r{reset}.log'
        cmd=[native['vvp'],str(out/f'{label}-{hz}.vvp'),f'+phase={phase}',f'+reset={reset}']
        with log.open('x') as stream:
            child=subprocess.Popen(cmd,stdout=stream,stderr=subprocess.STDOUT)
            try:
                affinity=sorted(os.sched_getaffinity(child.pid));assert affinity==[12,13]
                code=child.wait(timeout=30)
            except BaseException:child.kill();child.wait();raise
        good=grade(case,code,log.read_text())
        row=dict(case=case,passed=good,native_exit=code,native_pid=child.pid,waited=True,
            affinity=affinity,command=cmd,log=str(log),log_sha256=sha(log),image_sha256=sha(cmd[1]))
        print(json.dumps({k:row[k] for k in ('case','passed','native_exit')}),flush=True)
        return row
    try:
        for label,hz in itertools.product(('parent','candidate'),(3125000,40000000)):
            cmd=[native['iverilog'],'-g2012','-Wall','-s','tb_kbd_controller_inhibit',
                 f'-Ptb_kbd_controller_inhibit.HZ={hz}','-DVEN_KBC_FAST','-DVEN_KBD_AUTOACK',
                 '-o',str(out/f'{label}-{hz}.vvp'),*[str(src/n) for n in
                    ('controller.v','simple_fifo.v',label+'.v','tb_kbd_controller_inhibit.sv')]]
            log=out/f'{label}-{hz}-compile.log'
            with log.open('x') as stream:
                proc=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,timeout=30)
            builds.append(dict(command=cmd,native_exit=proc.returncode,log=str(log),log_sha256=sha(log)))
            assert proc.returncode==0
        with ThreadPoolExecutor(max_workers=2) as pool:
            for row in pool.map(execute,selected):
                rows.append(row)
                if not row['passed']:errors.append(row['case'])
    except Exception as exc:errors.append(repr(exc))
    events={k:int(v) for k,v in (s.split() for s in (cg/'memory.events').read_text().splitlines())}
    stable=all(sha(p)==h for p,h in pins.items())
    passed=not errors and stable and len(rows)==len(selected) and not any(events[k] for k in ('oom','oom_kill','oom_group_kill'))
    done=dict(passed=passed,rows=rows,builds=builds,errors=errors,pins_unchanged=stable,
        memory_events=events,memory_peak=int((cg/'memory.peak').read_text()),seconds=time.monotonic()-begin,
        physical_fpga=False,standard_suite=False,debug_mmio_tested=False,gameplay_ipc=None)
    save('closed.json',done)
    print(json.dumps({k:v for k,v in done.items() if k not in ('rows','builds')}),flush=True)
    return 0 if passed else 1


if __name__=='__main__':raise SystemExit(main())
