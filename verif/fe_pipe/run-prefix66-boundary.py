#!/usr/bin/env python3
"""Actual cold paging/CS/SMC cases, complete QEMU traces, no observer repair."""
import argparse, concurrent.futures, hashlib, importlib.util, json, os
from pathlib import Path
import re, shutil, socket, subprocess, sys, time

HERE=Path(__file__).resolve().parent;REPO=HERE.parents[1]
sys.path[:0]=[str(REPO/'verif/diff'),str(REPO/'verif/sys')]
import compare, tracefmt, check_faultlog
spec=importlib.util.spec_from_file_location('native',REPO/'verif/sys/run-native-system.py')
native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def save(p,v):
    with p.open('x') as f:json.dump(v,f,indent=2)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--control',type=Path,required=True)
    ap.add_argument('--candidate',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--kind',type=int,action='append')
    ap.add_argument('--offset',type=int,action='append')
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch) and shutil.disk_usage(scratch).free>1024**3
    args.out.mkdir()
    models={k:getattr(args,k).resolve(strict=True) for k in ('control','candidate')}
    source=HERE/'prefix66-boundary.S';linker=REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    pins={str(p):sha(p) for p in (Path(__file__),source,linker,qemu,
        REPO/'verif/qemu-trace/gen_trace.py',REPO/'verif/diff/tracefmt.py',
        REPO/'verif/diff/compare.py',REPO/'verif/sys/check_faultlog.py',
        REPO/'verif/sys/run-native-system.py')}
    profiles={}
    for name,model in models.items():
        stamp=model.parent/'Vventium_top__verFiles.dat'
        line=next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        defs=set(re.findall(r'\+define\+(\w+)',line));profiles[name]=defs
        assert ' --assert ' in line and {'VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SEG_ENFORCE','VEN_FE_PIPE','VEN_P54_PREFIX66_REG','VEN_L1_AXI'}<=defs
        assert not {'VEN_SYS_FASTPATH_ALL','SYNTHESIS','VTM_NO_DPI','VEN_UOPCACHE'}&defs
        for p in (model,stamp):pins[str(p)]=sha(p)
    assert profiles['candidate']==profiles['control']|{'VEN_P54_PREFIX66_SYSTEM'}
    kinds=sorted(set(args.kind or range(4)));offsets=sorted(set(args.offset or (4080,4093,4094,4095)))
    assert all(k in range(4) for k in kinds) and all(o in (4080,4093,4094,4095) for o in offsets)
    cases=[(k,r,o) for k in kinds for r in (0,1) for o in offsets if k!=1 or o>4092]
    save(args.out/'started.json',dict(pins=pins,cases=cases,invocation=os.environ.get('INVOCATION_ID')))
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','QEMU_','AXI_'))}
    env.update(TMPDIR=str(args.out),PYTHONDONTWRITEBYTECODE='1')
    def run(leaf,name,command,expected=0,latency=0):
        argv=['timeout','--signal=TERM','--kill-after=3s','45s',*map(str,command)]
        save(leaf/(name+'.argv.json'),argv)
        with (leaf/(name+'.stdout')).open('x') as out,(leaf/(name+'.stderr')).open('x') as err:
            rc=subprocess.run(argv,stdout=out,stderr=err,env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency))).returncode
        save(leaf/(name+'.exit.json'),dict(native_exit=rc))
        assert rc==expected,(leaf.name,name,rc,expected)
        return (leaf/(name+'.stdout')).read_text(),(leaf/(name+'.stderr')).read_text()
    def one(case):
        kind,reloc,offset=case;leaf=args.out/f'k{kind}-r{reloc}-o{offset}';leaf.mkdir()
        obj,elf,image=[leaf/('test.'+e) for e in ('o','elf','bin')]
        run(leaf,'assemble',['gcc','-m32','-nostdlib','-ffreestanding','-fno-pie','-fno-pic',
            f'-DKIND={kind}',f'-DRELOC={reloc}',f'-DOFFSET={offset}','-c',source,'-o',obj])
        run(leaf,'link',['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
            '-Wl,--build-id=none',obj,'-o',elf])
        run(leaf,'binary',['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image])
        symbols={p[2]:int(p[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                 if len(p:=line.split())==3 and p[0]!='U'}
        assert image.stat().st_size==65536 and symbols['hot_probe']==0x2f000+offset
        run(leaf,'free-qemu',[qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,
            '-display','none','-serial','none','-monitor','none','-no-reboot','-no-shutdown',
            '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],133)
        with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        golden=leaf/'golden.vtrace'
        run(leaf,'golden',[sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,
            '--system','--image',image,'--image-mode','bios','--cpu','pentium','--out',golden,
            '--max-insn','2000','--port',port])
        gold=tracefmt.read_trace(str(golden));assert 100<len(gold.records)<2000
        assert int(gold.records[-1]['eax'],0)&255==0x42
        rows=[]
        for name,model in models.items():
            for latency in (0,7):
                clocks={}
                for mode in ('cycle-func','cycle'):
                    stem=f'{name}-lat{latency}-{mode}';path=leaf/(stem+'.vtrace')
                    out,err=run(leaf,stem,[model,'--system','--cosim','--'+mode,'--l1-axi',
                        '--image',image,'--out',path,'--max-insn','2000','--max-cycles','1000000',
                        '--quiesce','4096','+ven_faultlog'],133,latency)
                    trace=tracefmt.read_trace(str(path))
                    assert [r['n'] for r in trace.records]==list(range(len(gold.records)))
                    assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records]
                    expected={(14,0):1} if kind==1 else ({(13,0):1} if kind==2 else {})
                    check_faultlog.check_counts(check_faultlog.read_counts(out.splitlines()),expected)
                    assert not native.FATAL.search(out) and not native.FATAL.search(err)
                    footer=re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) after (\d+) retired in (\d+) clocks$',err,re.M)
                    assert len(footer)==1 and int(footer[0][0])==len(trace.records)
                    clocks[mode]=int(footer[0][1])
                    if mode=='cycle-func':
                        native.grade_native(trace,out,err,133,133,2000)
                        with (leaf/(stem+'-diff.log')).open('x') as f:
                            assert compare.compare_func(gold,trace,False,0xffffffff,False,20,f,sys_both=True)==0
                    else:
                        paired=[r for r in trace.records if r.get('paired') and r.get('pipe')=='V']
                        assert paired,'UV never exercised'
                        rows.append(dict(case=case,model=name,latency=latency,clocks=clocks[mode],
                            pairs=len(paired),prefix_v=sum(int(r['pc'],0)==symbols['hot_probe']+4 for r in paired)))
                assert clocks['cycle']==clocks['cycle-func']
        save(leaf/'closed.json',dict(passed=True,measurements=rows));return rows
    result=dict(passed=False,errors=[],measurements=[],gameplay_ipc=None,standard_suite=False)
    start=time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        pending={pool.submit(one,c):c for c in cases}
        for future in concurrent.futures.as_completed(pending):
            try:result['measurements'].extend(future.result())
            except Exception as exc:result['errors'].append(dict(case=pending[future],error=repr(exc)))
    result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-start,
        all_children_reaped=True)
    result['passed']=not result['errors'] and result['pins_unchanged'] and len(result['measurements'])==len(cases)*4
    save(args.out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'},indent=2),flush=True)
    return 0 if result['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
