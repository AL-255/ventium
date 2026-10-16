"""Bounded actual-injector/8042 FIFO-pressure matrix; no core or CAD build."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import run_kbd_controller_inhibit as inputs

ROOT, REPO, sha = inputs.ROOT, inputs.REPO, inputs.sha
PARENT = inputs.CONTROLLER.with_name('parent.v')
PARENT_SHA = '2ee3b64fc24875b3aaca0e6296a2514161f19cef5e6f79aa90923ca06f1846da'


def cases():
    return list(itertools.product(('candidate','parent'), (3125000,40000000), (0,1), (0,1), (0,1)))


def grade(case, code, text):
    label, hz, during, translated, flip = case
    if label == 'parent' and during:
        return code == 1 and 'KBD-BACKPRESSURE-DATA' in text and 'KBD-BACKPRESSURE-OK' not in text
    expected = (f'KBD-BACKPRESSURE-OK hz={hz} during={during} translate={translated} '
                f'flip={flip} frames=2 reads=66 pending={int(label=="candidate" and during)}')
    return code == 0 and text.splitlines()[0] == expected and 'FATAL' not in text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args(); out = a.out.resolve()
    assert __debug__ and out.parent == ROOT and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    assert ROOT.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(ROOT).free > 4*1024**3
    assert sorted(os.sched_getaffinity(0)) == [12,13] and os.environ['INVOCATION_ID']
    cg = Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0 < int((cg/'memory.max').read_text()) <= 512*1024**2
    assert (cg/'memory.swap.max').read_text().strip() == '0' and 0 < int((cg/'pids.max').read_text()) <= 32
    for p,h in ((inputs.CONTROLLER,inputs.CONTROLLER_SHA),(inputs.FIFO,inputs.FIFO_SHA),
                (inputs.FIXED,inputs.FIXED_SHA),(PARENT,PARENT_SHA)):
        assert sha(p) == h, p
    files = {'candidate.v':inputs.CONTROLLER,'parent.v':PARENT,'simple_fifo.v':inputs.FIFO,
             'ven_ps2_kbd_inject.v':inputs.FIXED,'tb_kbd_backpressure.sv':REPO/'fpga/tb_kbd_backpressure.sv'}
    pins = {str(p):sha(p) for p in [*files.values(),Path(__file__).resolve(),Path(inputs.__file__).resolve()]}
    out.mkdir(); src = out/'source'; src.mkdir()
    for name,p in files.items():
        shutil.copyfile(p,src/name); assert sha(src/name) == sha(p); pins[str(src/name)] = sha(src/name)
    tools = {n:str(Path(shutil.which(n)).resolve(strict=True)) for n in ('iverilog','vvp')}
    pins.update({p:sha(p) for p in tools.values()})

    def save(name,value):
        with (out/name).open('x') as stream: json.dump(value,stream,indent=2)

    selected = cases()
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cases=selected,
        definitions=['VEN_KBC_FAST','VEN_KBD_AUTOACK'],read_only_candidate_probe='CHECK_RETAINED'))
    began = time.monotonic(); rows=[]; builds=[]; errors=[]

    def execute(case):
        label,hz,during,translated,flip = case
        assert time.monotonic()-began < 280
        name = f'{label}-{hz}-d{during}-t{translated}-f{flip}'; log = out/(name+'.log')
        command = [tools['vvp'],str(out/f'{label}-{hz}.vvp'),f'+during={during}',
                   f'+translate={translated}',f'+flip={flip}']
        with log.open('x') as stream:
            child = subprocess.Popen(command,stdout=stream,stderr=subprocess.STDOUT)
            try:
                affinity = sorted(os.sched_getaffinity(child.pid)); assert affinity == [12,13]
                rc = child.wait(timeout=30)
            except BaseException: child.kill(); child.wait(); raise
        row = dict(case=case,command=command,native_exit=rc,native_pid=child.pid,waited=True,
            affinity=affinity,passed=grade(case,rc,log.read_text()),log=str(log),
            log_sha256=sha(log),image_sha256=sha(command[1]))
        print(json.dumps({k:row[k] for k in ('case','native_exit','passed')}),flush=True)
        return row

    try:
        for label,hz in itertools.product(('candidate','parent'),(3125000,40000000)):
            command = [tools['iverilog'],'-g2012','-Wall','-s','tb_kbd_backpressure',
                f'-Ptb_kbd_backpressure.HZ={hz}','-DVEN_KBC_FAST','-DVEN_KBD_AUTOACK',
                *(['-DCHECK_RETAINED'] if label=='candidate' else []),'-o',str(out/f'{label}-{hz}.vvp'),
                *[str(src/n) for n in (label+'.v','simple_fifo.v','ven_ps2_kbd_inject.v','tb_kbd_backpressure.sv')]]
            log = out/f'{label}-{hz}-compile.log'
            with log.open('x') as stream:
                built = subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=30)
            builds.append(dict(command=command,native_exit=built.returncode,log=str(log),log_sha256=sha(log)))
            assert built.returncode == 0
        with ThreadPoolExecutor(max_workers=2) as pool:
            for row in pool.map(execute,selected):
                rows.append(row)
                if not row['passed']: errors.append(row['case'])
    except Exception as exc: errors.append(repr(exc))
    stable = all(sha(p)==h for p,h in pins.items())
    events = {k:int(v) for k,v in (s.split() for s in (cg/'memory.events').read_text().splitlines())}
    passed = not errors and stable and len(rows)==len(selected) and not any(events[k] for k in ('oom','oom_kill','oom_group_kill'))
    result = dict(passed=passed,pins_unchanged=stable,rows=rows,builds=builds,errors=errors,
        memory_events=events,memory_peak=int((cg/'memory.peak').read_text()),seconds=time.monotonic()-began,
        physical_fpga=False,debug_mmio=False,standard_suite=False,gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','builds')}),flush=True)
    return 0 if passed else 1


if __name__ == '__main__': raise SystemExit(main())
