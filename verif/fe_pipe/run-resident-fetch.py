#!/usr/bin/env python3
"""Full, unfiltered QEMU comparison of a cold UV-fast slow-fetch microbenchmark.

Uses a prebuilt model; no heavy build, saved state, mode downgrade or changes
to an active guest. The baseline may pass correctness while the fetch shortcut
remains disabled. --require-resident adds the separate implementation witness.
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

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt
spec = importlib.util.spec_from_file_location('native', REPO/'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tb',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--offsets',type=int,nargs='+',default=list(range(32)))
    parser.add_argument('--require-resident',action='store_true')
    args = parser.parse_args()
    assert __debug__
    assert len(args.offsets)==len(set(args.offsets)) and all(0<=x<32 for x in args.offsets)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    assert shutil.disk_usage(scratch).free>2*1024**3
    args.out.mkdir()
    tb=args.tb.resolve(strict=True)
    stamp=tb.parent/'Vventium_top__verFiles.dat'
    commands=[line for line in stamp.read_text().splitlines() if line.startswith('C ')]
    assert len(commands)==1 and ' --assert ' in commands[0]
    defines=set(re.findall(r'\+define\+(\w+)',commands[0]))
    assert {'VEN_IC_BRAM','VEN_FE_PIPE','VEN_SFETCH_RESIDENT','VEN_L1_AXI',
            'VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_PERF_PROFILE'}<=defines
    assert not {'VEN_UOPCACHE','VEN_FE_MEM_CHAIN','SYNTHESIS','VTM_NO_DPI'}&defines
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    linker=REPO/'verif/sys/tests/ppage/ppage.ld'
    pins={str(p):sha(p) for p in [Path(__file__),HERE/'resident-fetch.S',tb,stamp,qemu,linker,
          REPO/'verif/qemu-trace/gen_trace.py',REPO/'verif/diff/compare.py',
          REPO/'verif/diff/tracefmt.py',REPO/'verif/sys/run-native-system.py']}
    (args.out/'inputs.json').write_text(json.dumps(pins,indent=2)+'\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(args.out),PYTHONDONTWRITEBYTECODE='1')

    def run(argv,stem,expected=0,latency=0):
        # timeout owns the entire foreground native job; outer systemd service
        # supplies group-wide memory/time/cleanup containment.
        command=['timeout','--signal=TERM','--kill-after=3s','90s',*map(str,argv)]
        (args.out/(stem+'.command.json')).write_text(json.dumps(command,indent=2)+'\n')
        with (args.out/(stem+'.stdout')).open('xb') as out, (args.out/(stem+'.stderr')).open('xb') as err:
            result=subprocess.run(command,stdout=out,stderr=err,
                                  env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)))
        (args.out/(stem+'.exit')).write_text(str(result.returncode)+'\n')
        assert result.returncode==expected,(stem,result.returncode,expected)
        return result.returncode

    def check(offset):
        directory=args.out/f'o{offset}'
        directory.mkdir()
        obj,elf,image=[directory/('fixture.'+s) for s in ('o','elf','bin')]
        stem=f'o{offset}'
        run(['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',f'-DOFFSET={offset}',
             '-c',HERE/'resident-fetch.S','-o',obj],stem+'-assemble')
        run(['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
             '-Wl,--build-id=none',obj,'-o',elf],stem+'-link')
        run(['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image],stem+'-binary')
        assert image.stat().st_size==65536
        symbols={p[2]:int(p[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                 if len(p:=line.split())==3}
        assert symbols['hot_loop']%32==offset
        run([qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,'-display','none',
             '-serial','none','-monitor','none','-no-reboot','-no-shutdown',
             '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],stem+'-qemu',133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
        golden=directory/'golden.vtrace'
        run([sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,'--system',
             '--image',image,'--image-mode','bios','--cpu','pentium','--out',golden,
             '--max-insn','2000','--port',str(port)],stem+'-golden')
        results=[]
        for latency in (0,7):
            traces={}
            for mode in ('cycle-func','cycle'):
                case=f'{stem}-lat{latency}-{mode}'
                path=args.out/(case+'.vtrace')
                status=run([tb,'--system','--cosim','--'+mode,'--l1-axi','--image',image,
                    '--out',path,'--max-insn','2000','--max-cycles','1000000','--quiesce','200000',
                    '+ven_fetchdbg','+ven_fetchdbg_max=10000'],case,133,latency)
                parsed=tracefmt.read_trace(str(path))
                traces[mode]=parsed.records
                log=(args.out/(case+'.stdout')).read_text()
                if mode=='cycle-func':
                    native.grade_native(parsed,log,(args.out/(case+'.stderr')).read_text(),status,133,2000)
                    run([sys.executable,'-B',REPO/'verif/diff/compare.py','--mode','func','--all',
                         '--max-report','8',golden,path],case+'-compare')
            cycle=traces['cycle']
            assert [r['pc'] for r in cycle]==[r['pc'] for r in traces['cycle-func']]
            hits=[i for i,r in enumerate(cycle) if int(r['pc'],16)==symbols['hot_loop']]
            assert len(hits)==10
            pairs=[r for r in cycle if int(r['pc'],16)==symbols['pair_v'] and r.get('pipe')=='V' and r.get('paired')]
            assert len(pairs)==10,'every loop iteration must exercise its U/V pair'
            windows=[cycle[b]['cyc']-cycle[a]['cyc'] for a,b in zip(hits[2:-1],hits[3:])]
            resident=sum(f'eip={symbols[name]:08x} ' in line and '[FETCHDBG:CACHE]' in line
                         for line in log.splitlines() for name in ('hot_loop','pop_site'))
            results.append(dict(offset=offset,latency=latency,warm_round_cycles=windows,
                                paired_v=len(pairs),resident_offers=resident,records=len(cycle)))
        return results

    receipt=dict(passed=False,gameplay_ipc=None,standard_suite=False,definitions=sorted(defines),
                 cases=[],errors=[])
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            pending={pool.submit(check,offset):offset for offset in args.offsets}
            for future in concurrent.futures.as_completed(pending):
                try:
                    receipt['cases'].extend(future.result())
                except Exception as exc:
                    receipt['errors'].append(dict(offset=pending[future],error=str(exc)))
        receipt['cases'].sort(key=lambda r:(r['offset'],r['latency']))
        if args.require_resident:
            if not any(r['resident_offers']>0 for r in receipt['cases']):
                receipt['errors'].append(dict(error='shortcut never exercised'))
        receipt['passed']=not receipt['errors']
    finally:
        receipt['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        receipt['passed'] &= receipt['inputs_unchanged']
        (args.out/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
    assert receipt['passed']
    print(json.dumps(receipt,indent=2),flush=True)


if __name__=='__main__':
    main()
