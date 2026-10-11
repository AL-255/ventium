#!/usr/bin/env python3
"""Same-profile held-read address A/B, cold reset and complete QEMU/clock comparison."""
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
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('control','candidate','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models={n:getattr(args,n).resolve(strict=True) for n in ('control','candidate')}
    prerequisites={'VEN_PIPE_MEM_CHAIN','VEN_PIPE_REG_LOAD_PRIME','VEN_RAW_V_READ_PRIME'}
    prerequisites |= {'VEN_RAW_HELD_READ_PRIME'}
    profiles={}
    pins={}
    for name,tb in models.items():
        stamp=tb.parent/'Vventium_top__verFiles.dat'
        command=next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        assert ' --assert ' in command
        profiles[name]=set(re.findall(r'\+define\+(\w+)',command))
        assert {'VEN_L1_AXI','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_FE_PIPE',
                'VEN_IC_BRAM','VEN_P54_DUAL_LOAD_PAIR'} <= profiles[name]
        assert not {'VEN_UOPCACHE','VTM_NO_DPI','SYNTHESIS','VEN_SYS_FASTPATH_ALL'} & profiles[name]
        pins.update({str(p):sha(p) for p in (tb,stamp)})
    assert profiles['candidate']==profiles['control']
    assert prerequisites <= profiles['control']
    source=REPO/'verif/fe_pipe/raw-v-prime.S'
    linker=REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__),source,linker,qemu,REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py'):
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
        leaf=args.out/f'k{kind}-r{reloc}-o{offset}'
        leaf.mkdir()
        obj,elf,image=[leaf/('fixture.'+x) for x in ('o','elf','bin')]
        run(['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
             f'-DKIND={kind}',f'-DRELOC={reloc}',f'-DOFFSET={offset}','-c',source,'-o',obj],leaf,'assemble')
        run(['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
             '-Wl,--build-id=none',obj,'-o',elf],leaf,'link')
        run(['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image],leaf,'binary')
        assert image.stat().st_size==65536
        symbols={p[2]:int(p[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                 if len(p:=line.split())==3 and p[0] != 'U'}
        assert symbols['hot_loop']%32==offset
        run([qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,'-display','none',
             '-serial','none','-monitor','none','-no-reboot','-no-shutdown',
             '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],leaf,'free-qemu',133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        run([sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,'--system',
             '--image',image,'--image-mode','bios','--cpu','pentium','--out',leaf/'golden.vtrace',
             '--max-insn','5000','--port',str(port)],leaf,'golden')
        golden=tracefmt.read_trace(str(leaf/'golden.vtrace'))
        assert 100<len(golden.records)<5000 and int(golden.records[-1]['eax'],0)&255==0x42
        results=[]
        for latency in (0,7):
            measurements={}; full_traces={}
            for name,tb in models.items():
                traces={}
                for mode in ('cycle-func','cycle'):
                    stem=f'{name}-l{latency}-{mode}'
                    path=leaf/(stem+'.vtrace')
                    run([tb,'--system','--cosim','--'+mode,'--l1-axi','--image',image,
                         '--out',path,'--max-insn','5000','--max-cycles','3000000',
                         '--quiesce','4096','+ven_fetchdbg','+ven_fetchdbg_max=10000'],leaf,stem,133,latency)
                    trace=tracefmt.read_trace(str(path));traces[mode]=trace
                    assert [r['pc'] for r in trace.records]==[r['pc'] for r in golden.records]
                    assert [r['n'] for r in trace.records]==list(range(len(trace.records)))
                    text=(leaf/(stem+'.stdout')).read_text()+'\n'+(leaf/(stem+'.stderr')).read_text()
                    assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL',text)
                    footer=re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                                      r'after (\d+) retired in (\d+) clocks$',text,re.M)
                    assert len(footer)==1 and int(footer[0][0])==len(trace.records)
                    if mode=='cycle-func':
                        assert trace.hdr.get('sys') is True
                        for record in trace.records:
                            assert all(k in record for k in tracefmt.SYS_CR)
                        run([sys.executable,'-B',REPO/'verif/diff/compare.py','--mode','func',
                             '--all','--max-report','8',leaf/'golden.vtrace',path],leaf,stem+'-diff')
                full_traces[name] = {k:v.records for k,v in traces.items()}
                rows=traces['cycle'].records
                hits=[i for i,r in enumerate(rows) if int(r['pc'],0)==symbols['hot_loop']]
                assert len(hits)==16
                pairs=[r for r in rows if r.get('pipe')=='V' and r.get('paired')]
                assert pairs and any(int(r['pc'],0)==symbols['pair_v'] for r in pairs)
                warm=[rows[b]['cyc']-rows[a]['cyc'] for a,b in zip(hits[3:-1],hits[4:])]
                prime_pcs=[int(x,16) for x in re.findall(r'\[FETCHDBG:RAWPRIME\] eip=[0-9a-f]+ next=([0-9a-f]+)',text)]
                query_primes=prime_pcs.count(symbols['query_load'])
                if kind in (1,3):
                    assert query_primes==0,(case,name,'unsafe or control prime',query_primes)
                held_primes=len(re.findall(r'\[FETCHDBG:HELDPRIME\]',text))
                load_pairs=sum(int(r['pc'],0)==symbols.get('load_pair_v',-1) for r in pairs)
                measurements[name]=dict(warm_cycles=warm,query_primes=query_primes,
                    all_primes=len(prime_pcs),paired_v=len(pairs),load_pairs=load_pairs,
                    records=len(rows),held_primes=held_primes)
            a,b=measurements['control'],measurements['candidate']
            assert full_traces['control'] == full_traces['candidate'], (case, latency, 'complete A/B mismatch')
            assert a == b, (case, latency, 'hint ownership or performance changed')
            if kind == 5:
                assert a['held_primes'] >= 12, ('missing actual held-read witnesses', measurements)
            else:
                assert a['held_primes'] == 0, ('unexpected held-read hint', measurements)
            if kind == 2:
                assert a['load_pairs'] == b['load_pairs'] == 16
            results.append(dict(kind=kind,reloc=reloc,offset=offset,latency=latency,
                measurements=measurements,gain_fraction=1-sum(b['warm_cycles'])/sum(a['warm_cycles']),
                pair_preserved=b['load_pairs']==a['load_pairs']))
        return results

    result=dict(passed=False,cases=[],errors=[],invocation=os.environ.get('INVOCATION_ID'),gameplay_ipc=None,standard_suite=False,feature='same-profile-held-read')
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            pending={pool.submit(check,c):c for c in
                     [(k,r,o) for k in range(6) for r in (0,1) for o in (0,31)]}
            for future in concurrent.futures.as_completed(pending):
                try: result['cases'].extend(future.result())
                except Exception as exc:
                    result['errors'].append(dict(case=pending[future],error=repr(exc),
                                                 traceback=traceback.format_exc()))
        result['passed']=len(result['cases'])==48 and not result['errors']
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        (args.out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='cases'},indent=2),flush=True)
    assert result['passed']


if __name__=='__main__': main()
