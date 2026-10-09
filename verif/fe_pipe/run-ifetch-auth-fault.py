#!/usr/bin/env python3
"""Warm code permission and remap microgate; full pinned-QEMU state diff."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import traceback

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
sys.path[:0]=[str(REPO/'verif/diff'),str(REPO/'verif/sys')]
import tracefmt
import check_faultlog
from x87_event_compare import compare_complete

def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def save(p,v):
    with p.open('x') as f:json.dump(v,f,indent=2)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('control','candidate','out'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--feature',choices=('VEN_IFETCH_AUTH_MULTI','VEN_P54_CTRL_TARGET_SYSTEM'),
                        default='VEN_IFETCH_AUTH_MULTI')
    parser.add_argument('--fixture',choices=('single-page','warm-boundary'),default='single-page')
    args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models={n:getattr(args,n).resolve(strict=True) for n in ('control','candidate')}
    profiles={}; pins={}
    for n,tb in models.items():
        stamp=tb.parent/'Vventium_top__verFiles.dat'
        line=next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        profiles[n]=set(re.findall(r'\+define\+(\w+)',line))
        assert ' --assert ' in line
        assert {'VEN_L1_AXI','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_FE_PIPE'}<=profiles[n]
        assert not {'VEN_UOPCACHE','VTM_NO_DPI','SYNTHESIS','VEN_SYS_FASTPATH_ALL'}&profiles[n]
        pins.update({str(p):sha(p) for p in (tb,stamp)})
    assert profiles['candidate']==profiles['control']|{args.feature}
    assert args.feature not in profiles['control']
    if args.feature=='VEN_P54_CTRL_TARGET_SYSTEM':
        assert 'VEN_IFETCH_AUTH_MULTI' in profiles['control']
    source=HERE/('ifetch-auth-boundary.S' if args.fixture=='warm-boundary' else 'ifetch-auth-fault.S')
    ld=REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__),source,ld,qemu,REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py',
              REPO/'verif/sys/x87_event_compare.py',REPO/'verif/sys/check_faultlog.py'):
        pins[str(p)]=sha(p)
    save(args.out/'inputs.json',pins)
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(args.out),PYTHONDONTWRITEBYTECODE='1')
    def run(argv,leaf,name,expected=0,latency=0):
        command=['timeout','--signal=TERM','--kill-after=3s','60s',*map(str,argv)]
        save(leaf/(name+'.command.json'),command)
        with (leaf/(name+'.stdout')).open('x') as so,(leaf/(name+'.stderr')).open('x') as se:
            rc=subprocess.run(command,env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),
                              stdout=so,stderr=se).returncode
        save(leaf/(name+'.exit.json'),dict(exit=rc));assert rc==expected,(name,rc,expected)
        return (leaf/(name+'.stdout')).read_text(),(leaf/(name+'.stderr')).read_text()
    def prepare(case):
        leaf=args.out/f'case{case}';leaf.mkdir()
        obj,elf,image=[leaf/('fixture.'+e) for e in ('o','elf','bin')]
        run(['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',f'-DCASE={case}',
             '-c',source,'-o',obj],leaf,'assemble')
        run(['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(ld),'-Wl,--build-id=none',
             obj,'-o',elf],leaf,'link')
        run(['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image],leaf,'binary')
        assert image.stat().st_size==65536
        syms={p[2]:int(p[0],16) for l in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
              if len(p:=l.split())==3 and p[0]!='U'}
        assert syms['target']%4096==0
        if args.fixture=='single-page':assert syms['replacement']%4096==0
        run([qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,'-display','none',
             '-serial','none','-monitor','none','-no-reboot','-no-shutdown',
             '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],leaf,'free-qemu',133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        run([sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,'--system','--x87',
             '--image',image,'--image-mode','bios','--cpu','pentium','--out',leaf/'golden.vtrace',
             '--max-insn','5000','--port',str(port)],leaf,'golden')
        gold=tracefmt.read_trace(str(leaf/'golden.vtrace'))
        assert 100<len(gold.records)<5000 and int(gold.records[-1]['eax'],0)&255==0x42
        return case,leaf,image,syms,gold
    def measure(job):
        prepared,name,latency=job
        case,leaf,image,syms,gold=prepared
        pair_count=0
        for mode in ('cycle-func','cycle'):
            stem=f'{name}-l{latency}-{mode}';path=leaf/(stem+'.vtrace')
            so,se=run([models[name],'+ven_faultlog','--system','--cosim','--x87','--'+mode,'--l1-axi',
                      '--image',image,'--out',path,'--max-insn','5000','--max-cycles','3000000',
                      '--quiesce','200000'],leaf,stem,133,latency)
            trace=tracefmt.read_trace(str(path))
            assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records]
            assert [r['n'] for r in trace.records]==list(range(len(trace.records)))
            assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL',so+se)
            pf_error=4 if args.fixture=='warm-boundary' and case==2 else 5
            check_faultlog.check_counts(check_faultlog.read_counts(so.splitlines()),{} if case==3 else {(14,pf_error):1})
            footer=re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) after (\d+) retired in (\d+) clocks$',se,re.M)
            assert len(footer)==1 and int(footer[0][0])==len(trace.records)
            if mode=='cycle-func':
                with (leaf/(stem+'-diff.log')).open('x') as log:
                    assert compare_complete(gold,trace,log)==0
            else:
                pairs=[r for r in trace.records if r.get('pipe')=='V' and r.get('paired')]
                assert any(int(r['pc'],0)==syms['pair_v'] for r in pairs)
                pair_count=len(pairs)
        return dict(case=case,model=name,latency=latency,full_qemu_diff=True,paired_v=pair_count)
    result=dict(passed=False,cases=[],errors=[],gameplay_ipc=None,standard_suite=False,
                fixture=args.fixture,feature=args.feature)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:fixtures=list(pool.map(prepare,range(4)))
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
            tasks=[pool.submit(measure,(case,name,lat)) for case in fixtures for name in models for lat in (0,7)]
            for task in concurrent.futures.as_completed(tasks):
                try:result['cases'].append(task.result())
                except Exception as exc:result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
        assert len(result['cases'])==16 and not result['errors']
        result['passed']=True
    except Exception as exc:result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged'];save(args.out/'result.json',result)
    print(json.dumps(result,indent=2),flush=True);assert result['passed']

if __name__=='__main__':main()
