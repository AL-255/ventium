"""Bounded C++ host-protocol regression; no RTL, PC model or CAD build."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

HERE=Path(__file__).resolve().parent
ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    out=parser.parse_args().out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    assert out.parent.resolve(strict=True)==ROOT and not out.exists()
    assert sorted(os.sched_getaffinity(0))==[12,13]
    assert shutil.disk_usage(ROOT).free>4*1024**3
    group=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((group/'memory.max').read_text())<=512*1024**2
    assert (group/'memory.swap.max').read_text().strip()=='0'
    assert 0<int((group/'pids.max').read_text())<=32
    names=('ui_input_host.h','pc_keyboard_input.h','pc_keyboard_retained.h',
           'test_ui_input_host.cpp','test_pc_keyboard_input.cpp','test_ui_retained.cpp')
    out.mkdir(); source=out/'source'; source.mkdir(); work=out/'host-scratch'; work.mkdir()
    compiler=Path(shutil.which('g++')).resolve(strict=True)
    pins={str(p):sha(p) for p in [*[HERE/n for n in names],Path(__file__).resolve(),compiler]}
    for name in names:
        shutil.copyfile(HERE/name,source/name); assert sha(source/name)==pins[str(HERE/name)]
        pins[str(source/name)]=sha(source/name)
    def save(name,data):
        with (out/name).open('x') as stream: json.dump(data,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=[12,13],
        rtl_execution=False,physical_fpga=False,full_pc=False))
    start=time.monotonic(); rows=[]; errors=[]
    cases=(('test_ui_input_host','UI-HOST-MICRO-OK'),
           ('test_pc_keyboard_input','PC-KEYBOARD-BINDING-HOST-OK'),
           ('test_ui_retained','UI-RETAINED-HOST-OK'))
    def execute(case):
        name,marker=case; exe=out/name
        command=[str(compiler),'-std=c++17','-O1','-g','-Wall','-Wextra','-Werror',
                 '-fsanitize=address,undefined','-fno-omit-frame-pointer','-I',str(source),
                 str(source/(name+'.cpp')),'-o',str(exe)]
        log=out/(name+'-compile.log')
        with log.open('x') as stream:
            compiled=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=90)
        assert compiled.returncode==0, name+' compile failed'
        argv=[str(exe)]+([str(work)] if name=='test_ui_input_host' else [])
        native_log=out/(name+'.log')
        with native_log.open('x') as stream:
            child=subprocess.Popen(argv,stdout=stream,stderr=subprocess.STDOUT)
            affinity=sorted(os.sched_getaffinity(child.pid)); assert affinity==[12,13]
            try: code=child.wait(timeout=30)
            except BaseException:
                child.kill(); child.wait(); raise
        text=native_log.read_text()
        good=code==0 and marker in text and not any(s in text for s in ('Sanitizer','runtime error:'))
        row=dict(name=name,passed=good,compile_command=command,compile_exit=compiled.returncode,
                 command=argv,native_exit=code,affinity=affinity,binary_sha256=sha(exe),
                 logs={str(p):sha(p) for p in (log,native_log)})
        print(json.dumps({k:row[k] for k in ('name','passed','compile_exit','native_exit')}),flush=True)
        return row
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            for row in pool.map(execute,cases):
                rows.append(row)
                if not row['passed']: errors.append(row['name'])
    except Exception as exc: errors.append(repr(exc))
    stable=all(sha(p)==h for p,h in pins.items())
    events={k:int(v) for k,v in (line.split() for line in (group/'memory.events').read_text().splitlines())}
    result=dict(passed=not errors and stable and len(rows)==3 and not any(events[k] for k in ('oom','oom_kill','oom_group_kill')),
        rows=rows,errors=errors,pins_unchanged=stable,memory_events=events,
        memory_peak=int((group/'memory.peak').read_text()),seconds=time.monotonic()-start,
        rtl_execution=False,full_pc=False,physical_fpga=False,gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
