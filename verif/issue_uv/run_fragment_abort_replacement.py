#!/usr/bin/env python3
"""Probe cold/warm crossing IDT delivery after a real page-fragment fault.

Private ISA fixtures derived from pxfrag; no architectural state injection or
RTL rebuild. A passing architectural trace alone does not prove that the abort
and replacement overlapped: that requires a separate internal-state witness.
"""
import argparse
import concurrent.futures
import hashlib
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

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import compare
import tracefmt
import run_bus_cancel_system as system_checks

SOURCE_SHA='24b52b3249def16ecf9f10921b4dc353b7a76ee123545fde36ddbeb9b59e9757'
MODEL_SHA='f2797f8c17cb6c7d8668432ae69dd42d427d25a3e3d3b3cd1452de8d6582b4bf'
ANCHOR='    /* ================= case A: frag2 abort + stale-frag1 poison ============ */'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def fixture(source, first, warm, cd):
    if hashlib.sha256(source.encode()).hexdigest()!=SOURCE_SHA or first not in (1,2,3):
        raise ValueError('fragment fixture drift or invalid page split')
    gate=0x9000-first
    substitutions=(('    movl    $0x00001070, %edi',f'    movl    $0x{gate:08X}, %edi'),
        ('    movl    $0x00001068, %edi',f'    movl    $0x{gate-8:08X}, %edi'),
        ('    movl    $0x00001000, 0x0492',f'    movl    $0x{gate-14*8:08X}, 0x0492'))
    result=source
    for before, after in substitutions:
        if result.count(before)!=1:
            raise ValueError('missing/ambiguous IDT relocation')
        result=result.replace(before,after)
    prefix='''    /* Explicit cache mode; all guest state changes execute normally. */
    movl    %cr0, %eax
    andl    $0x9FFFFFFF, %eax
'''
    if cd:
        prefix+='    orl     $0x40000000, %eax\n'
    prefix+='    movl    %eax, %cr0\n'
    if warm:
        prefix+='''    /* Warm the original first page before the two IDT pages. Revisit
     * both after parent fills, which invalidate the registered child TLB. */
    movl    0x00002FFC, %eax
    movl    0x00009000, %eax
    movl    0x00008FFC, %eax
    movl    0x00009000, %eax
    movl    0x00002FFC, %eax
    movl    0x00008FFC, %eax
'''
    if result.count(ANCHOR)!=1:
        raise ValueError('missing/ambiguous fragment entry')
    result=result.replace(ANCHOR,prefix+ANCHOR)
    original=result.replace(prefix+ANCHOR,ANCHOR)
    for before,after in reversed(substitutions):
        original=original.replace(after,before)
    if original!=source:
        raise ValueError('non-reversible fixture derivative')
    return result


def save(path,value):
    with path.open('x') as stream:
        json.dump(value,stream,indent=2)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    model=args.model.resolve(strict=True); out=args.out.resolve()
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>4*1024**3
    assert sha(model)==MODEL_SHA
    stamp=model.parent/'Vventium_top__verFiles.dat'
    command=next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
    definitions=set(re.findall(r'\+define\+(\w+)',command))
    assert {'VEN_FE_PIPE','VEN_FE_DTLB_MULTI','VEN_FE_DTLB_PERM','VEN_L1_AXI',
        'VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_SYS_FASTLOAD_FLAT',
        'VEN_SYS_FASTSTORE_FLAT','VEN_SEG_ENFORCE'} <= definitions
    assert '--assert' in command and not {'SYNTHESIS','VTM_NO_DPI'} & definitions
    source=REPO/'verif/sys/tests/pxfrag/pxfrag.S'
    linker=source.with_suffix('.ld')
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    native_path=REPO/'verif/sys/run-native-system.py'
    spec=importlib.util.spec_from_file_location('fragment_native',native_path)
    native=importlib.util.module_from_spec(spec); spec.loader.exec_module(native)
    paths=(model,stamp,source,linker,qemu,Path(__file__),Path(system_checks.__file__),native_path,
        REPO/'verif/qemu-trace/gen_trace.py',Path(compare.__file__),Path(tracefmt.__file__))
    pins={str(path):sha(path) for path in paths}
    out.mkdir()
    save(out/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)),model=MODEL_SHA,definitions=sorted(definitions),
        diagnostic=True,abort_replacement_overlap_proved=False))
    golden_lock=threading.Lock(); began=time.monotonic()

    def run(leaf,label,argv,expected,latency=0):
        argv=['timeout','--signal=TERM','--kill-after=2s','30s',*map(str,argv)]
        save(leaf/(label+'.command.json'),argv)
        with (leaf/(label+'.stdout')).open('x') as stdout, (leaf/(label+'.stderr')).open('x') as stderr:
            result=subprocess.run(argv,stdout=stdout,stderr=stderr,
                env={**os.environ,'AXI_RLAT':str(latency),'AXI_WLAT':str(latency)})
        save(leaf/(label+'.exit.json'),dict(native_exit=result.returncode,
            stdout_sha256=sha(leaf/(label+'.stdout')),stderr_sha256=sha(leaf/(label+'.stderr'))))
        assert result.returncode==expected,(label,result.returncode,expected)
        return (leaf/(label+'.stdout')).read_text(),(leaf/(label+'.stderr')).read_text()

    def check(first,warm,cd):
        name=f'first{first}-warm{int(warm)}-cd{int(cd)}'; leaf=out/name; leaf.mkdir()
        result=dict(name=name,passed=False,measurements=[],errors=[],abort_replacement_overlap_proved=False)
        try:
            assembly=leaf/'fixture.S'; assembly.write_text(fixture(source.read_text(),first,warm,cd))
            obj,elf,image=(leaf/('fixture.'+suffix) for suffix in ('o','elf','bin'))
            run(leaf,'assemble',['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
                '-Wall','-c',assembly,'-o',obj],0)
            run(leaf,'link',['ld','-m','elf_i386','-T',linker,obj,'-o',elf],0)
            run(leaf,'binary',['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image],0)
            assert image.stat().st_size==65536
            result.update(assembly_sha256=sha(assembly),image_sha256=sha(image))
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
                clocks=[]; full=None
                for mode in ('cycle-func','cycle'):
                    label=f'lat{latency}-{mode}'; trace_path=leaf/(label+'.vtrace')
                    stdout,stderr=run(leaf,label,[model,'--system','--cosim','--l1-axi','--'+mode,
                        '--image',image,'--out',trace_path,'--max-insn','3000','--max-cycles','3000000',
                        '--quiesce','8000','+ven_faultlog','+ven_xpagelog','+ven_tlbdbg',
                        '+ven_tlbdbg_lin=8000'],133,latency)
                    trace=tracefmt.read_trace(str(trace_path))
                    assert not native.FATAL.search(stdout+stderr)
                    assert [row['pc'] for row in trace.records]==[row['pc'] for row in golden.records]
                    if mode=='cycle-func':
                        checked=native.grade_native(trace,stdout,stderr,133,133,3000)
                        clocks.append(checked['clocks']); full=trace.records
                        system_checks.witness('pxfrag',trace)
                        with (leaf/(label+'-diff.log')).open('x') as log:
                            assert compare.compare_func(golden,trace,False,0xffffffff,False,20,log,sys_both=True)==0
                    else:
                        assert trace.mode=='cycle' and full is not None
                        clocks.append(int(re.findall(r'after \d+ retired in (\d+) clocks',stderr)[0]))
                        result['measurements'].append(dict(latency=latency,records=len(trace.records),
                            clocks=clocks[-1],paired_v=sum(row.get('pipe')=='V' and row.get('paired')
                                                         for row in trace.records)))
                assert clocks[0]==clocks[1]
            result['passed']=True
        except Exception as error:
            result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
        save(leaf/'closed.json',result)
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(check,first,warm,cd) for first in (1,2,3)
                 for warm in (False,True) for cd in (False,True)]
        cases=[future.result() for future in futures]
    stable=all(sha(path)==digest for path,digest in pins.items())
    result=dict(passed=all(case['passed'] for case in cases) and stable,
        cases=cases,pins=pins,pins_unchanged=stable,seconds=time.monotonic()-began,
        abort_replacement_overlap_proved=False,gameplay_ipc=None,standard_suite=False)
    save(out/'closed.json',result)
    print(json.dumps({key:value for key,value in result.items() if key!='pins'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
