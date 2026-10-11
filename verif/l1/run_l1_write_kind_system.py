#!/usr/bin/env python3
"""Cold paged load/store-pair A/B: complete QEMU state and identical retire clocks.

Uses the existing reset/paging/relocation scaffold, not a snapshot. Does not
modify goldens, skip paired U state, or remove terminal records.
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
import time

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
sys.path[:0]=[str(REPO/'verif/diff'),str(REPO/'verif/sys')]
import compare
import tracefmt
import check_faultlog
spec=importlib.util.spec_from_file_location('native',REPO/'verif/sys/run-native-system.py')
native=importlib.util.module_from_spec(spec); spec.loader.exec_module(native)

PATTERNS=(
    ('same-line', 'movl (%eax),%edx', 'movl %esi,4(%eax)'),
    ('other-line', 'movl (%eax),%edx', 'movl %esi,4(%edi)'),
    ('same-bank', 'movl (%eax),%edx', 'movl %esi,(%edi)'),
    ('alias', 'movl (%eax),%edx', 'movl %esi,(%eax)'),
    ('split', 'movl (%eax),%edx', 'movl %esi,31(%edi)'),
    ('store-read', 'movl %esi,(%eax)', 'movl 4(%edi),%edx'),
)


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def save(p,v):
    with p.open('x') as f: json.dump(v,f,indent=2); f.write('\n')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for flag in ('control','candidate','out'): ap.add_argument('--'+flag,type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    out=args.out.resolve(); assert __debug__ and out.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>2*1024**3
    out.mkdir()
    models={'control':args.control.resolve(strict=True),'candidate':args.candidate.resolve(strict=True)}
    pins={}; profiles={}
    for label,model in models.items():
        stamp=model.parent/'Vventium_top__verFiles.dat'
        command=next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
        defs=set(re.findall(r'\+define\+(\w+)',command)); profiles[label]=defs
        assert ' --assert ' in command
        assert {'VEN_P54_DUAL_LOAD_PAIR','VEN_P54_DUAL_READ_ALU_PAIR','VEN_SYS_FASTPATH_RELOC',
                'VEN_P54_DUAL_STORE_PAIR','VEN_P54_LOAD_STORE_PAIR',
                'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_FE_PIPE','VEN_L1_AXI'}<=defs
        assert not {'VEN_SYS_FASTPATH_ALL','SYNTHESIS','VTM_NO_DPI'}&defs
        for p in (model,stamp): pins[str(p)]=sha(p)
    assert profiles['control']==profiles['candidate']
    scaffold=REPO/'verif/fe_pipe/prefix-ex-system.S'
    linker=REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__),scaffold,linker,qemu,REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/compare.py',REPO/'verif/diff/tracefmt.py',
              REPO/'verif/sys/run-native-system.py',REPO/'verif/sys/check_faultlog.py'):
        pins[str(p)]=sha(p)
    text=scaffold.read_text()
    # Observe every store target through ordinary post-loop loads. Architectural
    # trace equality must check the backing/cache effect, not just the store PC.
    assert text.count('done:\n')==1
    text=text.replace('done:\n', 'done:\n'
        '    movl (%eax),%edx\n    movl 4(%eax),%ebx\n'
        '    movl (%edi),%ecx\n    movl 4(%edi),%esi\n'
        '    movl 31(%edi),%edx\n')
    assert text.count('hot_u:\n')==text.count('    incl %ebp\n')==1
    a,b=text.index('hot_u:\n'),text.index('    incl %ebp\n')
    for label,u,v in PATTERNS:
        source=out/(label+'.S')
        with source.open('x') as f:f.write(text[:a]+'hot_u:\n    '+u+'\nhot_load:\n    '+v+'\n'+text[b:])
        pins[str(source)]=sha(source)
    save(out/'started.json',dict(pins=pins,models={k:str(v) for k,v in models.items()},
        profiles={k:sorted(v) for k,v in profiles.items()},invocation=os.environ.get('INVOCATION_ID')))
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','QEMU_','AXI_'))}
    env.update(TMPDIR=str(out),PYTHONDONTWRITEBYTECODE='1')

    def run(leaf,label,command,expected=0,latency=0):
        command=['timeout','--kill-after=3s','45s',*map(str,command)]
        save(leaf/(label+'.command.json'),command)
        with (leaf/(label+'.stdout')).open('x') as stdout,(leaf/(label+'.stderr')).open('x') as stderr:
            p=subprocess.run(command,env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),
                             stdout=stdout,stderr=stderr)
        save(leaf/(label+'.exit.json'),dict(native_exit=p.returncode))
        assert p.returncode==expected,(leaf.name,label,p.returncode)
        return (leaf/(label+'.stdout')).read_text(),(leaf/(label+'.stderr')).read_text()

    def check(case):
        label,reloc,offset=case; leaf=out/f'{label}-r{reloc}-o{offset}'; leaf.mkdir()
        obj,elf,image=[leaf/('fixture.'+e) for e in ('o','elf','bin')]
        run(leaf,'assemble',['gcc','-m32','-nostdlib','-ffreestanding','-fno-pie','-fno-pic',
            f'-DRELOC={reloc}',f'-DOFFSET={offset}','-c',out/(label+'.S'),'-o',obj])
        run(leaf,'link',['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
                        '-Wl,--build-id=none',obj,'-o',elf])
        run(leaf,'binary',['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image])
        symbols={s[2]:int(s[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                 if len(s:=line.split())==3 and s[0]!='U'}
        assert image.stat().st_size==65536 and symbols['hot_u']%32==offset
        run(leaf,'free-qemu',[qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,
            '-display','none','-serial','none','-monitor','none','-no-reboot','-no-shutdown',
            '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],133)
        with socket.socket() as sock: sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
        goldpath=leaf/'golden.vtrace'
        run(leaf,'golden',[sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,
            '--system','--image',image,'--image-mode','bios','--cpu','pentium',
            '--out',goldpath,'--max-insn','2000','--port',port])
        gold=tracefmt.read_trace(str(goldpath)); assert gold.sys and 100<len(gold.records)<2000
        assert int(gold.records[-1]['eax'],0)&255==0x42
        measures=[]
        for latency in (0,7):
            both={}
            for name,model in models.items():
                traces={}; clocks={}
                for mode in ('cycle-func','cycle'):
                    stem=f'{name}-lat{latency}-{mode}'; path=leaf/(stem+'.vtrace')
                    stdout,stderr=run(leaf,stem,[model,'--system','--cosim','--'+mode,'--l1-axi',
                        '--image',image,'--out',path,'--max-insn','2000','--max-cycles','1000000',
                        '--quiesce','4096','+ven_faultlog'],133,latency)
                    tr=tracefmt.read_trace(str(path)); traces[mode]=tr.records
                    assert [r['n'] for r in tr.records]==list(range(len(gold.records)))
                    assert [r['pc'] for r in tr.records]==[r['pc'] for r in gold.records]
                    check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()),{})
                    assert not native.FATAL.search(stdout) and not native.FATAL.search(stderr)
                    stops=re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) after (\d+) retired in (\d+) clocks$',stderr,re.M)
                    assert len(stops)==1 and int(stops[0][0])==len(tr.records)
                    clocks[mode]=int(stops[0][1])
                    if mode=='cycle-func':
                        native.grade_native(tr,stdout,stderr,133,133,2000)
                        with (leaf/(stem+'-diff.log')).open('x') as log:
                            assert compare.compare_func(gold,tr,False,0xffffffff,False,20,log,sys_both=True)==0
                assert clocks['cycle']==clocks['cycle-func']
                both[name]=traces
                vr=[r for r in traces['cycle'] if int(r['pc'],0)==symbols['hot_load']]
                assert len(vr)==16
                memory_v=sum(r.get('pipe')=='V' and r.get('paired') for r in vr)
                if label in ('same-bank','alias','split'): assert memory_v==0,(case,name,memory_v)
                measures.append(dict(case=case,model=name,latency=latency,clocks=clocks['cycle'],
                    records=len(traces['cycle']),memory_v=memory_v,
                    state_sha256=hashlib.sha256(json.dumps(traces['cycle-func'],sort_keys=True).encode()).hexdigest(),
                    cycle_sha256=hashlib.sha256(json.dumps(traces['cycle'],sort_keys=True).encode()).hexdigest()))
            assert both['control']==both['candidate'],(case,latency,'A/B state or cycle difference')
        save(leaf/'closed.json',dict(passed=True,measurements=measures,image_sha256=sha(image)))
        return measures

    cases=[(p[0],r,o) for p in PATTERNS for r in (0,1) for o in (0,1,7,15,28,31)]
    result=dict(passed=False,errors=[],measurements=[],gameplay_ipc=None,standard_suite=False)
    start=time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures={pool.submit(check,c):c for c in cases}
        for future in concurrent.futures.as_completed(futures):
            try: result['measurements'].extend(future.result())
            except Exception as error: result['errors'].append(dict(case=futures[future],error=repr(error)))
    rows=result['measurements']
    result['memory_v_retirements']=sum(r['memory_v'] for r in rows if r['model']=='candidate')
    result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
    result['passed']=not result['errors'] and len(rows)==len(cases)*4 and result['pins_unchanged'] and result['memory_v_retirements']>0
    # Both intended load/store shapes must actually pair; fallback-only runs
    # cannot qualify this backing-direction change.
    result['paired_by_shape']={label:sum(r['memory_v'] for r in rows
        if r['model']=='candidate' and r['case'][0]==label) for label,_,_ in PATTERNS}
    result['passed'] &= all(result['paired_by_shape'][label]>0
                           for label in ('same-line','other-line'))
    result['seconds']=time.monotonic()-start
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
