#!/usr/bin/env python3
"""Cold regression: cached primed U must not orphan a fresh registered V.

--expect-assert is a red-test reproduction, never a correctness pass.
Fixtures use original protected/paged boot setup and architectural self-checks.
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

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt
import compare


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('control','candidate','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--expect-assert',action='store_true')
    parser.add_argument('--feature',choices=('raw-v','held-read'),default='raw-v')
    args=parser.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models={n:getattr(args,n).resolve(strict=True) for n in ('control','candidate')}
    source=REPO/'verif/fe_pipe/raw-v-prime.S'
    linker=REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    inputs=[Path(__file__),source,linker,qemu,REPO/'verif/qemu-trace/gen_trace.py',
            REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py']
    profiles={}
    for name,tb in models.items():
        stamp=tb.parent/'Vventium_top__verFiles.dat'
        cmd=next(l for l in stamp.read_text().splitlines() if l.startswith('C '))
        defs=set(re.findall(r'\+define\+(\w+)',cmd));profiles[name]=defs
        assert ' --assert ' in cmd
        assert {'VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_L1_AXI','VEN_FE_PIPE',
                'VEN_P54_DUAL_LOAD_PAIR','VEN_P54_DUAL_BYTE_LOAD_PAIR'}<=defs
        assert not {'VEN_UOPCACHE','SYNTHESIS','VTM_NO_DPI'}&defs
        inputs.extend([tb,stamp])
    prerequisites={'VEN_PIPE_MEM_CHAIN','VEN_PIPE_REG_LOAD_PRIME','VEN_RAW_V_READ_PRIME'}
    extra=prerequisites if args.feature=='raw-v' else {'VEN_RAW_HELD_READ_PRIME'}
    assert profiles['candidate']==profiles['control']|extra and extra<=profiles['candidate']
    if args.feature=='held-read':
        assert prerequisites<=profiles['control'] and not profiles['control'] & extra
        assert not args.expect_assert  # This is regression qualification, not the old broken model.
    pins={str(p):sha(p) for p in inputs}
    (args.out/'inputs.json').write_text(json.dumps(pins,indent=2)+'\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(args.out),PYTHONDONTWRITEBYTECODE='1')

    def run(argv,leaf,label,latency=0):
        argv=['timeout','--signal=TERM','--kill-after=3s','60s',*map(str,argv)]
        (leaf/(label+'.command.json')).write_text(json.dumps(argv,indent=2)+'\n')
        with (leaf/(label+'.stdout')).open('x') as out,(leaf/(label+'.stderr')).open('x') as err:
            rc=subprocess.run(argv,env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),stdout=out,stderr=err).returncode
        (leaf/(label+'.exit')).write_text(str(rc)+'\n')
        return rc,(leaf/(label+'.stdout')).read_text()+'\n'+(leaf/(label+'.stderr')).read_text()

    def check(case):
        reloc,same_line=case
        leaf=args.out/f'r{reloc}-same{same_line}';leaf.mkdir()
        text=source.read_text()
        # U uses bank 0. V uses bank 1, in the same line (immediate return)
        # or a different line (registered-only return). No third decoder.
        disp=4 if same_line else 68
        old='    movl $11,96(%ebp)'
        assert text.count(old)==1
        text=text.replace(old,old+f'\n    movl $0x13579bdf,{disp}(%ebp)')
        old='load_pair_v:\n    movl $0x13579bdf,%ebx'
        assert text.count(old)==1
        text=text.replace(old,f'load_pair_v:\n    movl {disp}(%ebp),%ebx')
        old='    cmpl $0x8fff0,%esp'
        assert text.count(old)==1
        text=text.replace(old,'    cmpl $0x13579bdf,%ebx\n    jne fail\n'+old)
        fixture=leaf/'fixture.S';fixture.write_text(text)
        obj,elf,image=[leaf/('fixture.'+e) for e in ('o','elf','bin')]
        assert run(['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
            '-DKIND=2',f'-DRELOC={reloc}','-DOFFSET=0','-c',fixture,'-o',obj],leaf,'assemble')[0]==0
        assert run(['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
            '-Wl,--build-id=none',obj,'-o',elf],leaf,'link')[0]==0
        assert run(['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image],leaf,'binary')[0]==0
        assert image.stat().st_size==65536
        symbols={p[2]:int(p[0],16) for l in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                 if len(p:=l.split())==3 and p[0]!='U'}
        assert run([qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,'-display','none',
            '-serial','none','-monitor','none','-no-reboot','-no-shutdown',
            '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],leaf,'free-qemu')[0]==133
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        assert run([sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,
            '--system','--image',image,'--image-mode','bios','--cpu','pentium',
            '--out',leaf/'golden.vtrace','--max-insn','5000','--port',str(port)],leaf,'golden')[0]==0
        gold=tracefmt.read_trace(str(leaf/'golden.vtrace'))
        assert 100<len(gold.records)<5000 and int(gold.records[-1]['eax'],0)&255==0x42
        rows=[]
        for lat in (0,7):
            for name,tb in models.items():
                for mode in ('cycle-func','cycle'):
                    label=f'{name}-l{lat}-{mode}';path=leaf/(label+'.vtrace')
                    rc,log=run([tb,'--system','--cosim','--'+mode,'--l1-axi','--image',image,
                        '--out',path,'--max-insn','5000','--max-cycles','3000000','--quiesce','4096',
                        '+ven_fetchdbg','+ven_fetchdbg_max=10000'],leaf,label,lat)
                    expected_red=args.expect_assert and name=='candidate' and not same_line
                    if expected_red:
                        assert rc!=133 and 'fresh V hit lacks an admitted registered U owner' in log,(case,label,rc)
                        rows.append(dict(case=case,model=name,latency=lat,mode=mode,expected_red=True))
                        continue
                    assert rc==133 and not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED',log),(case,label,rc)
                    trace=tracefmt.read_trace(str(path))
                    assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records]
                    assert [r['n'] for r in trace.records]==list(range(len(trace.records)))
                    if mode=='cycle-func':
                        assert trace.hdr.get('sys') is True
                        assert all(all(k in r for k in tracefmt.SYS_CR) for r in trace.records)
                        with (leaf/(label+'-diff.log')).open('x') as out:
                            assert compare.compare_func(gold,trace,True,0xffffffff,False,20,out,sys_both=True)==0
                    else:
                        pairs=[r for r in trace.records if r.get('pipe')=='V' and r.get('paired')]
                        assert any(int(r['pc'],0)==symbols['pair_v'] for r in pairs),'UV disabled'
                        load_pairs=sum(int(r['pc'],0)==symbols['load_pair_v'] for r in pairs)
                        if same_line: assert load_pairs>=12,('immediate load pairing lost',load_pairs)
                    rows.append(dict(case=case,model=name,latency=lat,mode=mode,expected_red=False,records=len(trace.records)))
        return rows

    result=dict(passed=False,cases=[],errors=[],red_reproduction=args.expect_assert,
                correctness_pass=False,gameplay_ipc=None,standard_suite=False,feature=args.feature)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            jobs={pool.submit(check,c):c for c in [(r,s) for r in (0,1) for s in (0,1)]}
            for job in concurrent.futures.as_completed(jobs):
                try: result['cases'].extend(job.result())
                except Exception as exc:
                    result['errors'].append(dict(case=jobs[job],error=repr(exc),traceback=traceback.format_exc()))
        result['passed']=not result['errors'] and len(result['cases'])==32
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        result['correctness_pass']=result['passed'] and not args.expect_assert
        (args.out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='cases'},indent=2),flush=True)
    assert result['passed']


if __name__=='__main__': main()
