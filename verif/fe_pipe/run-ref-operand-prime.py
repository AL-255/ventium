#!/usr/bin/env python3
"""Complete QEMU traces and fixed-work timing for the private resident prime.

Eight parallel QEMU preparers, then 32 RTL workers, all inside the caller's
bounded scope. This directed gate does not claim gameplay/suite acceptance.
"""
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
from x87_event_compare import compare_complete


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def save(p,v):
    with p.open('x') as f:json.dump(v,f,indent=2)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('control','candidate','out'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--smoke',action='store_true')
    args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models={n:getattr(args,n).resolve(strict=True) for n in ('control','candidate')}
    pins,profiles={},{}
    for n,tb in models.items():
        stamp=tb.parent/'Vventium_top__verFiles.dat'
        command=next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        assert ' --assert ' in command
        profiles[n]=set(re.findall(r'\+define\+(\w+)',command))
        assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
                'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_P54_INT_EXEC_OCC',
                'VEN_FP_SCALAR_DISPATCH','VEN_FP_SCALAR_LOAD_CMD','VEN_RAW_V_READ_PRIME'}<=profiles[n]
        assert not {'VEN_UOPCACHE','SYNTHESIS','VTM_NO_DPI','VEN_SYS_FASTPATH_ALL'}&profiles[n]
        pins.update({str(p):sha(p) for p in (tb,stamp)})
    assert profiles['candidate']==profiles['control']|{'VEN_REF_OPERAND_PRIME'}
    assert 'VEN_REF_OPERAND_PRIME' not in profiles['control']
    source=HERE/'ref-operand-prime.S'
    linker=REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__),source,linker,qemu,REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py',
              REPO/'verif/sys/x87_event_compare.py'):pins[str(p)]=sha(p)
    save(args.out/'inputs.json',pins)
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(args.out),PYTHONDONTWRITEBYTECODE='1')

    def run(command,leaf,name,expected=0,latency=0):
        argv=['timeout','--signal=TERM','--kill-after=3s','60s',*map(str,command)]
        save(leaf/(name+'.command.json'),argv)
        with (leaf/(name+'.stdout')).open('x') as out,(leaf/(name+'.stderr')).open('x') as err:
            rc=subprocess.run(argv,env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),
                              stdout=out,stderr=err).returncode
        save(leaf/(name+'.exit.json'),dict(exit=rc))
        assert rc==expected,(name,rc,expected)
        return (leaf/(name+'.stdout')).read_text()+'\n'+(leaf/(name+'.stderr')).read_text()

    def prepare(case):
        k,r,o,d=case
        leaf=args.out/f'k{k}-r{r}-o{o}-d{d}';leaf.mkdir()
        obj,elf,image=[leaf/('fixture.'+ext) for ext in ('o','elf','bin')]
        run(['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
             f'-DKIND={k}',f'-DRELOC={r}',f'-DOFFSET={o}',f'-DDATAOFFSET={d}',
             '-c',source,'-o',obj],leaf,'assemble')
        run(['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
             '-Wl,--build-id=none',obj,'-o',elf],leaf,'link')
        run(['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image],leaf,'binary')
        assert image.stat().st_size==65536
        symbols={p[2]:int(p[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                 if len(p:=line.split())==3 and p[0]!='U'}
        assert symbols['hot_loop']%32==o
        run([qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,'-display','none',
             '-serial','none','-monitor','none','-no-reboot','-no-shutdown',
             '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],leaf,'free-qemu',133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        run([sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,'--system',
             '--x87','--image',image,'--image-mode','bios','--cpu','pentium','--out',leaf/'golden.vtrace',
             '--max-insn','2000','--port',str(port)],leaf,'golden')
        gold=tracefmt.read_trace(str(leaf/'golden.vtrace'))
        assert 100<len(gold.records)<2000 and int(gold.records[-1]['eax'],0)&255==0x42
        return case,leaf,image,symbols,gold

    def measure(job):
        prepared,name,latency=job
        case,leaf,image,symbols,gold=prepared
        traces={};primes=0;clocks=0
        for mode in ('cycle-func','cycle'):
            stem=f'{name}-l{latency}-{mode}';path=leaf/(stem+'.vtrace')
            text=run([models[name],'+ven_fetchdbg','+ven_fetchdbg_max=10000',
                      '--system','--cosim','--x87','--'+mode,'--l1-axi','--image',image,
                      '--out',path,'--max-insn','2000','--max-cycles','3000000',
                      '--quiesce','200000'],leaf,stem,133,latency)
            trace=tracefmt.read_trace(str(path));traces[mode]=trace
            assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records]
            assert [r['n'] for r in trace.records]==list(range(len(trace.records)))
            assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL',text)
            footer=re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                              r'after (\d+) retired in (\d+) clocks$',text,re.M)
            assert len(footer)==1 and int(footer[0][0])==len(trace.records)
            clocks=int(footer[0][1])
            primes+=sum(symbols['hot_loop']<=int(pc,16)<symbols['hot_end']
                        for pc in re.findall(r'\[FETCHDBG:REFPRIME\] eip=([0-9a-f]+)',text))
            if mode=='cycle-func':
                assert trace.mode=='func' and trace.hdr.get('sys') is True and trace.x87
                with (leaf/(stem+'-diff.log')).open('x') as log:
                    assert compare_complete(gold,trace,log)==0,(case,name,latency,'complete QEMU state')
        rows=traces['cycle'].records
        hits=[i for i,r in enumerate(rows) if int(r['pc'],0)==symbols['hot_loop']]
        assert len(hits)==64
        pairs=[r for r in rows if r.get('pipe')=='V' and r.get('paired') and
               int(r['pc'],0)==symbols['pair_v']]
        assert len(pairs)==64,'missing actual U/V witness'
        warm=[rows[b]['cyc']-rows[a]['cyc'] for a,b in zip(hits[16:-1],hits[17:])]
        return dict(case=case,model=name,latency=latency,records=len(rows),paired_v=len(pairs),
                    total_clocks=clocks,warm_cycles=warm,resident_primes=primes,full_qemu_diff=True)

    cases=[(k,r,o,d) for k in range(10) for r in (0,1)
           for o in ((17,) if args.smoke else (0,17,31))
           for d in ((0,) if args.smoke else (0,1,28,29,31))]
    result=dict(passed=False,measurements=[],errors=[],gameplay_ipc=None,standard_suite=False)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            prepared=list(pool.map(prepare,cases))
        jobs=[(p,n,l) for p in prepared for n in models for l in (0,7)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
            pending={pool.submit(measure,j):j[0][0] for j in jobs}
            for future in concurrent.futures.as_completed(pending):
                try:result['measurements'].append(future.result())
                except Exception as exc:result['errors'].append(dict(case=pending[future],error=repr(exc),
                                                                    traceback=traceback.format_exc()))
        assert len(result['measurements'])==len(jobs) and not result['errors']
        indexed={(tuple(r['case']),r['model'],r['latency']):r for r in result['measurements']}
        gains=[]
        for case in cases:
            for latency in (0,7):
                a=indexed[case,'control',latency];b=indexed[case,'candidate',latency]
                assert a['resident_primes']==0
                assert b['total_clocks']<=a['total_clocks'],('whole-program regression',case,latency,a,b)
                assert sum(b['warm_cycles'])<=sum(a['warm_cycles']),('warm regression',case,latency)
                if case[0]>=7:
                    assert b['resident_primes']==0 and b['warm_cycles']==a['warm_cycles'],('negative control',case)
                gains.append(dict(case=case,latency=latency,control=sum(a['warm_cycles']),
                                  candidate=sum(b['warm_cycles']),fraction=1-sum(b['warm_cycles'])/sum(a['warm_cycles'])))
        assert any(r['resident_primes'] for r in result['measurements'])
        assert any(g['fraction']>0 for g in gains),'no measured clock saving'
        result.update(passed=True,gains=gains)
    except Exception as exc:result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged'];save(args.out/'result.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('measurements','gains')},indent=2))
    assert result['passed']


if __name__=='__main__':main()
