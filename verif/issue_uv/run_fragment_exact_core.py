#!/usr/bin/env python3
"""Full-core exact-read regression on the twelve archived crossing-IDT cases.

Fresh QEMU goldens, full architectural and cycle streams, actual paired V
retirements. Correcting bus widths may change cycles: record every cycle
difference without treating this directed test as the canonical cycle gate.
"""
import argparse
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import traceback

import build_fragment_exact_core as builder
import run_fragment_abort_replacement as fixtures
import run_bus_cancel_system as system_checks
from prepare_fragment_exact_reads import transform

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import compare
import tracefmt

sha, save, load, stable = builder.sha, builder.save, builder.load, builder.stable


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('build','corpus','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    build, corpus, out=args.build.resolve(strict=True),args.corpus.resolve(strict=True),args.out.resolve()
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert Path(os.environ['TMPDIR']).resolve()==scratch and out.is_relative_to(scratch) and not out.exists()
    assert shutil.disk_usage(scratch).free>4*1024**3
    prepared, closed=load(build/'prepared.json'),load(build/'build-closed.json')
    assert closed['passed'] and closed['native_exit']==0 and closed['pins_unchanged']
    assert stable(prepared['pins']) and prepared['parent_model']==builder.MODEL
    model=build/'obj/tb_ventium'; assert sha(model)==closed['binary_sha256']
    parent=Path(prepared['parent'])
    oldcore=parent/'candidate/rtl/core'
    assert (build/'candidate/rtl/core/core.sv').read_text()==transform(
        (oldcore/'core.sv').read_text(),(oldcore/'core_bus_driver.svh').read_text())
    stamp=build/'obj/Vventium_top__verFiles.dat'
    command=next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
    definitions=set(re.findall(r'\+define\+(\w+)',command))
    assert definitions==set(prepared['definitions']) and len(definitions)==150 and '--assert' in command
    assert not {'SYNTHESIS','VTM_NO_DPI'} & definitions
    old=load(corpus/'closed.json')
    assert old['passed'] and old['pins_unchanged'] and stable(old['pins']) and len(old['cases'])==12
    native_path=REPO/'verif/sys/run-native-system.py'
    spec=importlib.util.spec_from_file_location('fragment_native',native_path)
    native=importlib.util.module_from_spec(spec); spec.loader.exec_module(native)
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    source=REPO/'verif/sys/tests/pxfrag/pxfrag.S'
    paths=[model,stamp,Path(__file__),Path(builder.__file__),Path(fixtures.__file__),
        Path(system_checks.__file__),source,qemu,native_path,REPO/'verif/qemu-trace/gen_trace.py',
        Path(compare.__file__),Path(tracefmt.__file__),build/'prepared.json',build/'build-closed.json',
        corpus/'closed.json']
    pins={str(path):sha(path) for path in paths}
    out.mkdir(); began=time.monotonic(); golden_lock=threading.Lock()
    save(out/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)),model=sha(model),definitions=sorted(definitions),
        fresh_qemu_goldens=True,cycle_changes_reported_not_waived=True,standard_suite=False))
    env={key:value for key,value in os.environ.items() if not key.startswith(('VEN_','VTM_','TB_','QEMU_','AXI_','FP_'))}
    env.update(TMPDIR=str(scratch),PYTHONDONTWRITEBYTECODE='1')

    def run(leaf,label,argv,expected,latency=0):
        argv=['timeout','--signal=TERM','--kill-after=2s','30s',*map(str,argv)]
        save(leaf/(label+'.command.json'),argv)
        with (leaf/(label+'.stdout')).open('x') as stdout,(leaf/(label+'.stderr')).open('x') as stderr:
            result=subprocess.run(argv,stdout=stdout,stderr=stderr,
                env={**env,'AXI_RLAT':str(latency),'AXI_WLAT':str(latency)})
        save(leaf/(label+'.exit.json'),dict(native_exit=result.returncode,
            stdout_sha256=sha(leaf/(label+'.stdout')),stderr_sha256=sha(leaf/(label+'.stderr'))))
        assert result.returncode==expected,(label,result.returncode,expected)
        return (leaf/(label+'.stdout')).read_text(),(leaf/(label+'.stderr')).read_text()

    def check(oldcase):
        name=oldcase['name']; oldleaf=corpus/name; leaf=out/name; leaf.mkdir()
        result=dict(name=name,passed=False,measurements=[],errors=[])
        casepins={}
        try:
            parsed=re.fullmatch(r'first([123])-warm([01])-cd([01])',name)
            assert parsed and oldcase['passed']
            first,warm,cd=map(int,parsed.groups())
            assert (oldleaf/'fixture.S').read_text()==fixtures.fixture(source.read_text(),first,bool(warm),bool(cd))
            image=oldleaf/'fixture.bin'
            assert sha(image)==oldcase['image_sha256'] and image.stat().st_size==65536
            casepins.update({str(path):sha(path) for path in (image,oldleaf/'fixture.S',oldleaf/'closed.json')})
            run(leaf,'qemu-free',[qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,
                '-display','none','-serial','stdio','-monitor','none','-no-reboot','-no-shutdown',
                '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],133)
            with golden_lock:
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
                run(leaf,'golden',[sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py',
                    '--qemu',qemu,'--system','--cpu','pentium','--image',image,'--image-mode','bios',
                    '--out',leaf/'golden.vtrace','--max-insn','3000','--port',port],0)
            golden=tracefmt.read_trace(str(leaf/'golden.vtrace'))
            system_checks.witness('pxfrag',golden)
            for latency in (0,7):
                streams={}; clocks=[]
                for mode in ('cycle-func','cycle'):
                    label=f'lat{latency}-{mode}'; path=leaf/(label+'.vtrace')
                    previous=oldleaf/(label+'.vtrace'); casepins[str(previous)]=sha(previous)
                    stdout,stderr=run(leaf,label,[model,'--system','--cosim','--l1-axi','--'+mode,
                        '--image',image,'--out',path,'--max-insn','3000','--max-cycles','3000000',
                        '--quiesce','8000','+ven_faultlog'],133,latency)
                    trace=tracefmt.read_trace(str(path)); prior=tracefmt.read_trace(str(previous))
                    assert not native.FATAL.search(stdout+stderr)
                    assert [row['pc'] for row in trace.records]==[row['pc'] for row in golden.records]
                    assert [row['n'] for row in trace.records]==list(range(len(trace.records)))
                    clocks.append(int(re.findall(r'after \d+ retired in (\d+) clocks',stderr)[0]))
                    if mode=='cycle-func':
                        native.grade_native(trace,stdout,stderr,133,133,3000)
                        system_checks.witness('pxfrag',trace)
                        with (leaf/(label+'-diff.log')).open('x') as log:
                            assert compare.compare_func(golden,trace,False,0xffffffff,False,20,log,sys_both=True)==0
                        assert trace.records==prior.records,'architectural predecessor difference'
                    else:
                        assert trace.mode=='cycle'
                        oldmeasure=next(row for row in oldcase['measurements'] if row['latency']==latency)
                        paired=sum(row.get('pipe')=='V' and row.get('paired') for row in trace.records)
                        assert paired>0
                        result['measurements'].append(dict(latency=latency,records=len(trace.records),
                            clocks=clocks[-1],parent_clocks=oldmeasure['clocks'],paired_v=paired,
                            cycle_records_changed=sum(a!=b for a,b in zip(trace.records,prior.records))))
                    streams[mode]=trace.records
                assert clocks[0]==clocks[1]
            result['passed']=True
        except Exception as error:
            result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
        result.update(pins=casepins,pins_unchanged=stable(casepins)); result['passed'] &= result['pins_unchanged']
        save(leaf/'closed.json',result)
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        cases=list(pool.map(check,old['cases']))
    result=dict(passed=all(case['passed'] for case in cases) and stable(pins),cases=cases,pins=pins,
        pins_unchanged=stable(pins),seconds=time.monotonic()-began,standard_suite=False,
        canonical_gate_passed=False,gameplay_ipc=None,byte_exact_bus_observed=False)
    save(out/'closed.json',result)
    print(json.dumps({key:value for key,value in result.items() if key not in ('pins','cases')},indent=2),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
