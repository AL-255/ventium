#!/usr/bin/env python3
"""Whole-state QEMU and UV-cycle regression for standalone cached-store inputs."""
from concurrent.futures import ThreadPoolExecutor
import argparse,hashlib,json,os,re,socket,subprocess,sys,time
from pathlib import Path
REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import compare,tracefmt
sys.path.insert(0,str(REPO/'verif/sys'))
import check_faultlog

def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    sources=[args.control,args.candidate,qemu,Path(__file__),
        REPO/'verif/tb/bfm_store_policy.h',REPO/'verif/tb/bfm_store_policy_bios.S',
        REPO/'verif/qemu-trace/gen_trace.py',REPO/'verif/diff/compare.py',
        REPO/'verif/diff/tracefmt.py',REPO/'verif/sys/check_faultlog.py']
    pins={str(p.resolve()):sha(p) for p in sources}
    with (out/'started.json').open('x') as f:json.dump(dict(pins=pins,gameplay_ipc=None),f,indent=2)
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(out),PYTHONDONTWRITEBYTECODE='1')
    deadline=time.monotonic()+540
    def run(cmd,directory,label,extra=None):
        with (directory/(label+'.cmd.json')).open('x') as f:json.dump([str(x) for x in cmd],f)
        with (directory/(label+'.log')).open('x') as stdout, (directory/(label+'.stderr')).open('x') as stderr:
            subprocess.run([str(x) for x in cmd],env=env|dict(extra or {}),cwd=REPO,
                stdout=stdout,stderr=stderr,check=True,timeout=min(120,deadline-time.monotonic()))
    cases=[]
    for offset in (0,1,2,3,28,30):
        row=out/f'offset-{offset}';row.mkdir()
        run(['as','--32','--defsym',f'OFFSET={offset}',REPO/'verif/tb/bfm_store_policy_bios.S','-o',row/'test.o'],row,'as')
        run(['ld','-m','elf_i386','-T',REPO/'verif/sys/tests/pmode/pmode.ld','-o',row/'test.elf',row/'test.o'],row,'ld')
        run(['objcopy','-O','binary',row/'test.elf',row/'test.bin'],row,'flat')
        run(['truncate','-s','65536',row/'test.bin'],row,'pad')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        run([sys.executable,REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,'--system',
             '--image',row/'test.bin','--image-mode','bios','--out',row/'qemu.vtrace',
             '--max-insn','3000','--port',str(port)],row,'qemu')
        assert 'guest exited, code=0' in (row/'qemu.stderr').read_text()
        cases.extend((offset,latency,label,binary) for latency in (0,7)
                     for label,binary in (('control',args.control),('candidate',args.candidate)))
    def execute(case):
        offset,latency,label,binary=case;parent=out/f'offset-{offset}'
        row=parent/f'{label}-lat{latency}';row.mkdir()
        results={}
        for mode in ('cycle-func','cycle'):
            run([binary,'--'+mode,'--system','--l1-axi','--image',parent/'test.bin',
                 '--out',row/(mode+'.vtrace'),'--max-insn','3000','--max-cycles','200000',
                 '--quiesce','2000','+ven_faultlog'],row,mode,
                 dict(AXI_RLAT=str(latency),AXI_WLAT=str(latency)))
            canonical=(row/(mode+'.log')).read_text();log=canonical+(row/(mode+'.stderr')).read_text()
            check_faultlog.check_counts(check_faultlog.read_counts(canonical.splitlines()),{})
            assert not re.search(r'%Error|%Fatal|Assertion failed|tb: FLT',log)
            assert 'stop: quiescent for 2000 clocks (core idle)' in log
            trace=tracefmt.read_trace(str(row/(mode+'.vtrace')))
            if mode=='cycle-func':
                assert int(trace.records[-1]['eax'],0)==0x42
                assert int(trace.records[-1]['edx'],0)==0xf4
                with (row/'compare.log').open('x') as stream:
                    assert compare.compare_func(tracefmt.read_trace(str(parent/'qemu.vtrace')),
                        trace,False,0xffffffff,False,20,stream)==0
            else:
                assert any(r.get('pipe')=='V' for r in trace.records),'UV path not exercised'
                results['clocks']=trace.records[-1]['cyc']
                results['retires']=len(trace.records)
            if label=='candidate':assert 'tb: [store-policy] backend=MemModel u=1 v=1 ' in log
        return dict(offset=offset,latency=latency,label=label,**results)
    with ThreadPoolExecutor(max_workers=8) as pool:results=list(pool.map(execute,cases))
    for offset in (0,1,2,3,28,30):
        for latency in (0,7):
            a,b=[next(r for r in results if (r['offset'],r['latency'],r['label'])==(offset,latency,label)) for label in ('control','candidate')]
            assert a['retires']==b['retires'] and b['clocks']<a['clocks'],(a,b)
    assert all(sha(p)==h for p,h in pins.items())
    with (out/'result.json').open('x') as f:json.dump(dict(passed=True,results=results,
        full_state_qemu_comparisons=24,cycle_executions=24,inputs_unchanged=True,
        gameplay_ipc=None,standard_suite=False,rtl_unchanged=True),f,indent=2)
    print('BFM-STORE-POLICY-CORE-OK',flush=True)

if __name__=='__main__':main()
