"""Real-iobus RX retention/self-test and actual FPGA mouse-transport checks.

Uses two bounded Icarus workers, not Verilator or Vivado. No live inputs changed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
BASE=ROOT/'ps2-loss-aux-iobus-r1/source'


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args(); out=args.out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    assert out.parent.resolve(strict=True)==ROOT and not out.exists()
    assert sorted(os.sched_getaffinity(0))==[12,13]
    invocation=os.environ['INVOCATION_ID']
    group=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((group/'memory.max').read_text())<=512*1024**2
    assert (group/'memory.swap.max').read_text().strip()=='0'
    assert 0<int((group/'pids.max').read_text())<=32
    assert shutil.disk_usage(ROOT).free>4*1024**3
    original=json.loads((BASE.parent/'started.json').read_text())
    assert original['candidate_sha256']=='9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405'
    files={name:BASE/name for name in ('parent.v','candidate.v','simple_fifo.v','iobus.v','tb_loss_aux_iobus.sv')}
    files.update({'loss_aux_skid_body.svh':HERE/'loss_aux_skid_body.svh',
                  'ven_ps2_device.sv':REPO/'fpga/ven_ps2_device.sv',
                  'tb_ps2_device.sv':REPO/'fpga/tb_ps2_device.sv',
                  'run_loss_aux_extended.py':Path(__file__).resolve()})
    for name in ('parent.v','candidate.v','simple_fifo.v','iobus.v','tb_loss_aux_iobus.sv'):
        # The original runner records the external symlink spelling. Resolve
        # both sides, require exactly one match, and still check its digest.
        matched=[digest for path,digest in original['pins'].items()
                 if Path(path).resolve(strict=True)==files[name]]
        assert len(matched)==1 and sha(files[name])==matched[0],name
    assert sha(files['tb_loss_aux_iobus.sv'])=='87312e9ee0e96f47bafb47f93ccea08c8b6e3c7c010e5d23e799b96442ca91c7'
    assert sha(files['ven_ps2_device.sv'])=='8db5ceb38d329590e293e49ef67e4f347fe93fde5877d233f877b661de7fde48'
    assert sha(files['tb_ps2_device.sv'])=='82d2bae54c414f3dcf4e52e35730d75dc3c27ffa50ffc0cffeb820e9d6bf6348'
    out.mkdir(); source=out/'source'; source.mkdir()
    pins={str(p):sha(p) for p in files.values()}
    for name,path in files.items():
        shutil.copyfile(path,source/name); assert sha(source/name)==pins[str(path)]
        pins[str(source/name)]=sha(source/name)
    text=(source/'tb_loss_aux_iobus.sv').read_text(); anchor='  initial begin\n'
    assert text.count(anchor)==1
    generated=source/'tb_loss_aux_skid.sv'
    with generated.open('x') as f:f.write(text[:text.index(anchor)]+(source/'loss_aux_skid_body.svh').read_text())
    pins[str(generated)]=sha(generated)
    tools={name:str(Path(shutil.which(name)).resolve(strict=True)) for name in ('iverilog','vvp','taskset')}
    pins.update({p:sha(p) for p in tools.values()})
    rows=[]; builds=[]; errors=[]; cases=[]
    for label in ('parent','candidate'):
        for scenario in ((3,5) if label=='parent' else (3,4,5)):
            for wait,translate in itertools.product((0,7),(0,1)):
                cases.append(dict(label=f'{label}-skid-{scenario}-w{wait}-t{translate}',
                    image=f'{label}-skid',args=[f'+scenario={scenario}','+half=1667',f'+wait={wait}',f'+translate={translate}'],
                    expected='loss' if label=='parent' else 'skid_pass',timeout=20))
        for autoack in (False,True):
            name=f'{label}-transport-autoack{int(autoack)}'
            cases.append(dict(label=name,image=name,args=[],expected='transport_pass',timeout=100))
    def save(name,obj):
        with (out/name).open('x') as f:json.dump(obj,f,indent=2)
    save('started.json',dict(pins=pins,invocation=invocation,affinity=[12,13],cases=cases,
         source_candidate=original['candidate_sha256'],full_pc=False,physical_fpga=False))
    start=time.monotonic()
    def compile_model(label,top,sources,defines):
        command=[tools['iverilog'],'-g2012','-Wall','-s',top,*['-D'+d for d in defines],
                 '-o',str(out/(label+'.vvp')),*map(str,sources)]
        with (out/(label+'-compile.log')).open('x') as f:
            result=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=30)
        builds.append(dict(command=command,native_exit=result.returncode))
        assert result.returncode==0,label+' compile failed'
    def execute(case):
        assert time.monotonic()-start<290 and shutil.disk_usage(ROOT).free>4*1024**3
        command=[tools['vvp'],str(out/(case['image']+'.vvp')),*case['args']]
        path=out/(case['label']+'.log')
        with path.open('x') as f:
            child=subprocess.Popen(command,stdout=f,stderr=subprocess.STDOUT)
            affinity=sorted(os.sched_getaffinity(child.pid)); assert affinity==[12,13]
            try:code=child.wait(timeout=case['timeout'])
            except BaseException:
                child.kill(); child.wait(); raise
        text=path.read_text(); expected=case['expected']
        if expected=='loss':good=code==1 and 'LOSS-AUX-RX-SKID-LOST' in text
        elif expected=='skid_pass':good=code==0 and 'LOSS-AUX-SKID-OK ' in text
        else:
            result=[tuple(map(int,m)) for m in re.findall(r'PS2-DEVICE-OK hz=(\d+) checks=(\d+) completed=(\d+) aborted=(\d+)',text)]
            good=(code==0 and sorted(result)==[(3125000,49,26,2),(40000000,49,26,2)]
                  and 'PS2-DEVICE-ALL-OK profiles=2' in text)
        row=dict(**case,command=command,native_exit=code,affinity=affinity,passed=good,
                 log=str(path),log_sha256=sha(path))
        print(json.dumps({k:row[k] for k in ('label','native_exit','expected','passed')}),flush=True)
        return row
    try:
        for label in ('parent','candidate'):
            compile_model(label+'-skid','tb_loss_aux_iobus',[source/(label+'.v'),source/'simple_fifo.v',source/'iobus.v',generated],
                          ['VEN_KBC_FAST','VEN_KBD_AUTOACK'])
            for autoack in (False,True):
                defs=['VEN_KBC_FAST']+(['VEN_KBD_AUTOACK'] if autoack else [])
                compile_model(f'{label}-transport-autoack{int(autoack)}','tb_ps2_device',
                    [source/(label+'.v'),source/'simple_fifo.v',source/'ven_ps2_device.sv',source/'tb_ps2_device.sv'],defs)
        with ThreadPoolExecutor(max_workers=2) as pool:
            for row in pool.map(execute,cases):
                rows.append(row)
                if not row['passed']:errors.append(row['label'])
    except Exception as exc:errors.append(repr(exc))
    stable=all(sha(p)==h for p,h in pins.items())
    events={k:int(v) for k,v in (s.split() for s in (group/'memory.events').read_text().splitlines())}
    result=dict(passed=not errors and stable and len(rows)==24 and not any(events[k] for k in ('oom','oom_kill','oom_group_kill')),
        rows=rows,builds=builds,errors=errors,pins_unchanged=stable,memory_events=events,
        memory_peak=int((group/'memory.peak').read_text()),seconds=time.monotonic()-start,
        full_pc=False,physical_fpga=False,standard_suite=False,gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','builds')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
