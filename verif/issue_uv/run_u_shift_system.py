#!/usr/bin/env python3
"""Cold paged shift/branch and memory-ALU checks on two same-profile UV models.

Prepare QEMU goldens sequentially; run RTL cases in parallel. Require entire
architectural/cycle A/B streams, reference correctness and actual U/V pairs.
No INT80 boundary omission, saved state, cache injection or debug stepping.
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
import traceback

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import tracefmt
import compare
import check_faultlog
spec = importlib.util.spec_from_file_location('native', REPO/'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value,stream,indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('control','candidate','out'):
        parser.add_argument('--'+key,type=Path,required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert shutil.disk_usage(scratch).free > 4*1024**3
    models = {n:getattr(args,n).resolve(strict=True) for n in ('control','candidate')}
    pins, profiles = {}, []
    for model in models.values():
        stamp = model.parent/'Vventium_top__verFiles.dat'
        cmd = next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
        defs = set(re.findall(r'\+define\+(\w+)',cmd))
        assert ' --assert ' in cmd
        assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_FAST_BYTE_SHIFT',
            'VEN_FAST_ROR_IMM','VEN_P54_PREFIX66_REG'} <= defs
        assert not {'SYNTHESIS','VTM_NO_DPI','VEN_SYS_FASTPATH_ALL'} & defs
        profiles.append(defs)
        pins.update({str(p):sha(p) for p in (model,stamp)})
    assert profiles[0] == profiles[1] and len(profiles[0]) == 150
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    source = Path(__file__).with_name('t_u_shift_registers.S')
    linker = REPO/'verif/sys/tests/ppage/ppage.ld'
    for p in (qemu,source,linker,Path(__file__),REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py',
              REPO/'verif/sys/run-native-system.py',REPO/'verif/sys/check_faultlog.py'):
        pins[str(p)] = sha(p)
    out.mkdir()
    cases = [(case,reloc,offset) for case in range(8) for reloc in (0,1) for offset in (0,7,15,30)]
    save(out/'started.json',dict(pins=pins,definitions=sorted(profiles[0]),cases=cases,
        models={k:str(v) for k,v in models.items()},invocation=os.environ['INVOCATION_ID'],
        sequential_goldens=True,rtl_workers=8,cycle_mode=1,debug_step=False))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','QEMU_','AXI_'))}
    env.update(TMPDIR=str(out),PYTHONDONTWRITEBYTECODE='1')
    result = dict(passed=False,errors=[],measurements=[],gameplay_ipc=None,standard_suite=False,hardware_acceptance=False)

    def run(folder,name,command,expected=0,latency=0):
        assert shutil.disk_usage(scratch).free > 4*1024**3
        command = ['timeout','--kill-after=3s','45s',*map(str,command)]
        save(folder/(name+'.command.json'),command)
        with (folder/(name+'.stdout')).open('x') as stdout, (folder/(name+'.stderr')).open('x') as stderr:
            rc = subprocess.run(command,env={**env,'AXI_RLAT':str(latency),'AXI_WLAT':str(latency)},
                stdout=stdout,stderr=stderr).returncode
        save(folder/(name+'.exit.json'),dict(native_exit=rc))
        assert rc == expected,(folder.name,name,rc,expected)
        return (folder/(name+'.stdout')).read_text(),(folder/(name+'.stderr')).read_text()

    fixtures = []
    try:
        for case,reloc,offset in cases:
            folder = out/f'c{case}-r{reloc}-o{offset}'
            folder.mkdir()
            obj,elf,image = [folder/('fixture.'+ext) for ext in ('o','elf','bin')]
            run(folder,'assemble',['gcc','-m32','-nostdlib','-ffreestanding','-fno-pie','-fno-pic',
                f'-DCASE={case}',f'-DRELOC={reloc}',f'-DOFFSET={offset}','-c',source,'-o',obj])
            run(folder,'link',['gcc','-m32','-static','-no-pie','-nostdlib',
                '-Wl,-T,'+str(linker),'-Wl,--build-id=none',obj,'-o',elf])
            run(folder,'binary',['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image])
            symbols = {p[2]:int(p[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                       if len(p:=line.split())==3 and p[0]!='U'}
            assert image.stat().st_size == 65536 and symbols['shift_subject']%32 == offset
            save(folder/'symbols.json',symbols)
            run(folder,'free-qemu',[qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,
                '-display','none','-serial','none','-monitor','none','-no-reboot','-no-shutdown',
                '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],133)
            with socket.socket() as sock:
                sock.bind(('127.0.0.1',0))
                port=sock.getsockname()[1]
            run(folder,'golden',[sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,
                '--system','--image',image,'--image-mode','bios','--cpu','pentium',
                '--out',folder/'golden.vtrace','--max-insn','2000','--port',port])
            assert not (folder/'golden.vtrace.qemu.stderr').read_text().strip(), 'QEMU startup failure'
            gold = tracefmt.read_trace(str(folder/'golden.vtrace'))
            assert gold.mode=='func' and gold.sys and not gold.x87 and 100<len(gold.records)<2000
            assert int(gold.records[-1]['eax'],0)&255 == 0x42
            assert sum(int(r['pc'],0)==symbols['shift_subject'] for r in gold.records)==8
            fixtures.append((case,reloc,offset,folder,image,symbols,gold))

        def check(fixture):
            case,reloc,offset,folder,image,symbols,gold = fixture
            measures=[]
            for latency in (0,7):
                both={}
                for name,model in models.items():
                    streams={}
                    for mode in ('cycle-func','cycle'):
                        stem=f'{name}-lat{latency}-{mode}'
                        path=folder/(stem+'.vtrace')
                        stdout,stderr=run(folder,stem,[model,'--system','--cosim','--'+mode,'--l1-axi',
                            '--image',image,'--out',path,'--max-insn','2000','--max-cycles','1000000',
                            '--quiesce','4096','+ven_faultlog'],133,latency)
                        trace=tracefmt.read_trace(str(path))
                        assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records]
                        assert [r['n'] for r in trace.records]==list(range(len(gold.records)))
                        check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()),{})
                        assert not native.FATAL.search(stdout) and not native.FATAL.search(stderr)
                        if mode=='cycle-func':
                            native.grade_native(trace,stdout,stderr,133,133,2000)
                            with (folder/(stem+'-diff.log')).open('x') as log:
                                assert compare.compare_func(gold,trace,False,0xffffffff,False,20,log,sys_both=True)==0
                        else:
                            assert trace.mode=='cycle' and not trace.sys
                        streams[mode]=trace.records
                    both[name]=streams
                    rows=streams['cycle']; paired=0
                    for index,row in enumerate(rows):
                        if int(row['pc'],0)==symbols['shift_subject']:
                            following=rows[index+1]
                            assert int(following['pc'],0)==symbols['shift_branch']
                            paired+=int(row['pipe']=='U' and following['pipe']=='V' and
                                following['paired'] and row['cyc']==following['cyc'])
                    # Line-straddling forms and RCR's ISA-required fallback are
                    # correctness controls. All ordinary register-shift cases
                    # at in-line offsets must actually pair their Jcc.
                    if case<6 and offset<=15:
                        assert paired==8,(case,reloc,offset,name,'suppressed UV pair',paired)
                    measures.append(dict(case=case,reloc=reloc,offset=offset,model=name,latency=latency,
                        records=len(rows),paired_subjects=paired,last_cycle=rows[-1]['cyc']))
                assert both['control']==both['candidate'], 'complete architectural/cycle streams differ'
            save(folder/'closed.json',dict(passed=True,measurements=measures,image_sha256=sha(image)))
            return measures
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures={pool.submit(check,f):f[:3] for f in fixtures}
            for future in concurrent.futures.as_completed(futures):
                try: result['measurements'].extend(future.result())
                except Exception as error:
                    result['errors'].append(dict(case=futures[future],error=repr(error),traceback=traceback.format_exc()))
        assert len(result['measurements'])==len(cases)*4 and not result['errors']
        result['passed']=True
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
    result['passed'] &= result['pins_unchanged']
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
