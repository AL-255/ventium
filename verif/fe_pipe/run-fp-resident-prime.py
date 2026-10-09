#!/usr/bin/env python3
"""Cold x87 operand-window A/B: all QEMU architectural records, UV fast + AXI."""
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


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('control','candidate','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--smoke',action='store_true')
    args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models={n:getattr(args,n).resolve(strict=True) for n in ('control','candidate')}
    pins,profiles={},{}
    for name,tb in models.items():
        stamp=tb.parent/'Vventium_top__verFiles.dat'
        command=next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        profiles[name]=set(re.findall(r'\+define\+(\w+)',command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_FE_PIPE',
                'VEN_RAW_V_READ_PRIME','VEN_FP_SHARED','VEN_FP_MEM_ADMIT',
                'VEN_L1D_BANKED_DATA','VEN_FP_LOAD64'} <= profiles[name]
        assert not {'VEN_UOPCACHE','VTM_NO_DPI','SYNTHESIS','VEN_SYS_FASTPATH_ALL'} & profiles[name]
        pins.update({str(p):sha(p) for p in (tb,stamp)})
    assert profiles['candidate']==profiles['control']|{'VEN_FP_RESIDENT_PRIME'}
    assert 'VEN_FP_RESIDENT_PRIME' not in profiles['control']
    source=HERE/'fp-resident-prime.S'
    linker=REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__),source,linker,qemu,REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py',
              REPO/'verif/sys/x87_event_compare.py'):
        pins[str(p)]=sha(p)
    (args.out/'inputs.json').write_text(json.dumps(pins,indent=2)+'\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(args.out),PYTHONDONTWRITEBYTECODE='1')

    def run(command,leaf,name,expected=0,latency=0):
        command=['timeout','--signal=TERM','--kill-after=3s','60s',*map(str,command)]
        (leaf/(name+'.command.json')).write_text(json.dumps(command,indent=2)+'\n')
        with (leaf/(name+'.stdout')).open('x') as output,(leaf/(name+'.stderr')).open('x') as errors:
            rc=subprocess.run(command,env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),
                              stdout=output,stderr=errors).returncode
        (leaf/(name+'.exit')).write_text(str(rc)+'\n')
        assert rc==expected,(name,rc,expected)

    def check(case):
        kind,reloc,offset=case
        leaf=args.out/f'k{kind}-r{reloc}-o{offset}';leaf.mkdir()
        obj,elf,image=[leaf/('fixture.'+x) for x in ('o','elf','bin')]
        run(['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
             f'-DKIND={kind}',f'-DRELOC={reloc}',f'-DOFFSET={offset}','-c',source,'-o',obj],leaf,'assemble')
        run(['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
             '-Wl,--build-id=none',obj,'-o',elf],leaf,'link')
        run(['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image],leaf,'binary')
        assert image.stat().st_size==65536
        symbols={p[2]:int(p[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                 if len(p:=line.split())==3 and p[0]!='U'}
        assert symbols['hot_loop']%32==offset
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
        results=[]
        for latency in (0,7):
            measurements={}
            for name,tb in models.items():
                traces={}
                for mode in ('cycle-func','cycle'):
                    stem=f'{name}-l{latency}-{mode}';path=leaf/(stem+'.vtrace')
                    run([tb,'--system','--cosim','--x87','--'+mode,'--l1-axi','--image',image,
                         '--out',path,'--max-insn','5000','--max-cycles','3000000',
                         '--quiesce','200000','+ven_fetchdbg','+ven_fetchdbg_max=10000'],leaf,stem,133,latency)
                    trace=tracefmt.read_trace(str(path));traces[mode]=trace
                    assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records]
                    assert [r['n'] for r in trace.records]==list(range(len(trace.records)))
                    text=(leaf/(stem+'.stdout')).read_text()+'\n'+(leaf/(stem+'.stderr')).read_text()
                    assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL',text)
                    footer=re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                                      r'after (\d+) retired in (\d+) clocks$',text,re.M)
                    assert len(footer)==1 and int(footer[0][0])==len(trace.records)
                    if mode=='cycle-func':
                        assert trace.mode=='func' and trace.hdr.get('sys') is True and trace.x87
                        with (leaf/(stem+'-diff.log')).open('x') as log:
                            assert compare_complete(gold,trace,log)==0,(case,name,latency,'full QEMU diff')
                rows=traces['cycle'].records
                hits=[i for i,r in enumerate(rows) if int(r['pc'],0)==symbols['hot_loop']]
                assert len(hits)==16
                pairs=[r for r in rows if r.get('pipe')=='V' and r.get('paired')]
                assert any(int(r['pc'],0)==symbols['pair_v'] for r in pairs),'no real UV witness'
                warm=[rows[b]['cyc']-rows[a]['cyc'] for a,b in zip(hits[3:-1],hits[4:])]
                primes=[int(x,16) for x in re.findall(r'\[FETCHDBG:FPPRIME\] eip=([0-9a-f]+)',text)]
                assert set(primes)<=set(symbols[f'operand{i}'] for i in range(4)),('unexpected FP prime',primes)
                if name=='control' or kind in (3,4):
                    assert not primes,('unsafe split/control prime',case,name,primes)
                measurements[name]=dict(warm_cycles=warm,prime_count=len(primes),paired_v=len(pairs),
                    records=len(rows),full_qemu_diff=True)
            a,b=measurements['control'],measurements['candidate']
            if kind in (3,4):
                assert b['warm_cycles']==a['warm_cycles'],('split fallback changed',measurements)
            else:
                assert b['prime_count']>=32,('missing actual FP prime witnesses',measurements)
                assert sum(b['warm_cycles'])<sum(a['warm_cycles']),('no directed gain',measurements)
            results.append(dict(kind=kind,reloc=reloc,offset=offset,latency=latency,
                measurements=measurements,gain_fraction=1-sum(b['warm_cycles'])/sum(a['warm_cycles'])))
        return results

    cases=[(0,0,0)] if args.smoke else [(k,r,o) for k in range(6) for r in (0,1) for o in (0,31)]
    result=dict(passed=False,cases=[],errors=[],gameplay_ipc=None,standard_suite=False,smoke=args.smoke)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
            pending={pool.submit(check,c):c for c in cases}
            for future in concurrent.futures.as_completed(pending):
                try: result['cases'].extend(future.result())
                except Exception as exc:
                    result['errors'].append(dict(case=pending[future],error=repr(exc),traceback=traceback.format_exc()))
        result['passed']=len(result['cases'])==len(cases)*2 and not result['errors']
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        (args.out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='cases'},indent=2),flush=True)
    assert result['passed']


if __name__=='__main__': main()
