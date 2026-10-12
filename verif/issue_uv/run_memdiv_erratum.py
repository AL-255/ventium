#!/usr/bin/env python3
"""Exercise memory divide bug selection using two existing UV-fast AXI models.

Not the canonical gate, a gameplay measurement, or physical-board acceptance.
No RTL compilation: only eight tiny assembly images and bounded native runs.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt
MODELS={'control':'d7d683b3e1d2ea70586b56f095a86e11fc1e37fa6889050caaa2d5541f8e5b77',
        'candidate':'be5375aa32db48600498fc4b2c3a610c7cd99a0fa208c5186e602c44dd9b3d10'}


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def rounded80(numerator,denominator):
    """Independent exact-integer nearest-even, positive finite normal quotient."""
    assert numerator>0 and denominator>0
    exponent=numerator.bit_length()-denominator.bit_length()
    if exponent>=0:
        if numerator < denominator << exponent: exponent-=1
    elif numerator << -exponent < denominator: exponent-=1
    shift=63-exponent
    a,b=(numerator<<shift,denominator) if shift>=0 else (numerator,denominator<<-shift)
    q,r=divmod(a,b)
    if 2*r>b or (2*r==b and q&1): q+=1
    if q==1<<64: q>>=1; exponent+=1
    assert 1<<63 <= q < 1<<64
    return ((exponent+16383)<<64)|q


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ('control','candidate','out'): parser.add_argument('--'+key,type=Path,required=True)
    args=parser.parse_args(); out=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert out!=scratch and out.is_relative_to(scratch) and not out.exists()
    assert shutil.disk_usage(scratch).free>4.5*1024**3
    assert rounded80(4195835,3145727)==0x3fffaabaa0e3e35a14bd
    models={k:getattr(args,k).resolve(strict=True) for k in MODELS}
    pins={str(p):sha(p) for p in (Path(__file__),REPO/'verif/issue_uv/memdiv-erratum.S',
          REPO/'verif/tests/elf2flat.py',Path(tracefmt.__file__),Path('/usr/bin/gcc'),Path('/usr/bin/nm'))}
    for key,model in models.items():
        assert sha(model)==MODELS[key]; pins[str(model)]=MODELS[key]
        start=model.parent.parent/'build-started.json'
        before=json.loads(start.read_text()); defs=set(before['definitions'])
        assert len(defs)==152 and {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH',
            'VEN_SYS_FASTPATH_RELOC','VEN_FP_SHARED','VEN_SRT_ITER'}<=defs
        assert not {'SYNTHESIS','VTM_NO_DPI','VEN_CACHE_HALF'}&defs
        pins[str(start)]=sha(start)
    out.mkdir()
    def save(p,value):
        with p.open('x') as f: json.dump(value,f,indent=2)
    save(out/'started.json',dict(pins=pins,models={k:str(v) for k,v in models.items()},
        invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0)),
        workers=4,rtl_compile=False,canonical_gate=False,standard_suite=False,gameplay_ipc=None))
    def native(folder,label,command,env):
        command=list(map(str,command)); save(folder/(label+'.command.json'),command)
        with (folder/(label+'.log')).open('x') as stream:
            with subprocess.Popen(command,env=env,stdout=stream,stderr=subprocess.STDOUT,
                                  start_new_session=True) as child:
                affinity=sorted(os.sched_getaffinity(child.pid))
                try: status=child.wait(timeout=20)
                except BaseException:
                    if child.poll() is None:
                        os.killpg(child.pid,signal.SIGTERM)
                        try: child.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid,signal.SIGKILL); child.wait(timeout=5)
                    raise
        assert affinity==sorted(os.sched_getaffinity(0)) and not Path('/proc',str(child.pid)).exists()
        save(folder/(label+'.exit.json'),dict(native_exit=status,affinity=affinity,pid=child.pid,reaped=True))
        assert status==0,(label,status)
        return (folder/(label+'.log')).read_text()
    def case(fmt,reverse):
        folder=out/f'f{fmt}-r{reverse}'; folder.mkdir()
        env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','AXI_','TB_'))}
        native(folder,'assemble',['/usr/bin/gcc','-m32','-march=pentium','-nostdlib','-static',
            '-Wl,--build-id=none','-Wl,-Ttext=0x08048000',f'-DFORMAT={fmt}',f'-DREVERSE={reverse}',
            REPO/'verif/issue_uv/memdiv-erratum.S','-o',folder/'fixture.elf'],env)
        native(folder,'flatten',[sys.executable,'-B',REPO/'verif/tests/elf2flat.py',folder/'fixture.elf',
            '--out',folder/'fixture.flat','--base','0x08048000'],env)
        symbols={r[2]:int(r[0],16) for s in subprocess.check_output(['/usr/bin/nm',str(folder/'fixture.elf')],
                  text=True).splitlines() if len(r:=s.split())==3}
        observations={}; rows=[]
        for bug in (0,1):
            expected=(0x3fffaab7f6392a768638 if bug else rounded80(4195835,3145727)) if fmt<3 else rounded80(29,7)
            for latency in (0,7):
                for key,model in models.items():
                    for mode in ('cycle-func','cycle'):
                        label=f'{key}-bug{bug}-lat{latency}-{mode}'; trace=folder/(label+'.vtrace')
                        command=[model,'--image',folder/'fixture.flat','--load','0x08048000',
                            '--entry','0x08048000','--out',trace,'--x87','--'+mode,'--l1-axi',
                            '--errata',str(bug),'--max-insn','200','--quiesce','20000']
                        log=native(folder,label,command,dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency),VEN_AXI_PROFILE='1'))
                        assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|reached --max',log),label
                        records=tracefmt.read_trace(str(trace)).records
                        assert records and int(records[-1]['pc'],0)==symbols['exit_int'],label
                        witnesses=[r for r in records if int(r['pc'],0)==symbols['quotient']]
                        assert len(witnesses)==1
                        if mode=='cycle-func':
                            actual=int(witnesses[0]['st0'],0)
                            assert actual==expected,(label,hex(actual),hex(expected))
                            assert int(records[-1]['eax'],0)==1 and int(records[-1]['ebx'],0)==0
                        else:
                            assert sum(r['pipe']=='V' and r['paired'] for r in records)>0,label
                        observations[bug,latency,key,mode]=records
                        rows.append(dict(format=fmt,reverse=reverse,bug=bug,latency=latency,model=key,
                            mode=mode,records=len(records),expected_st0=hex(expected),log_sha256=sha(folder/(label+'.log')),
                            actual_v=sum(r.get('pipe')=='V' and r.get('paired',False) for r in records)))
                assert observations[bug,latency,'control','cycle-func']==observations[bug,latency,'candidate','cycle-func']
                a,b=[observations[bug,latency,k,'cycle'] for k in models]
                assert [(r['n'],r['pc']) for r in a]==[(r['n'],r['pc']) for r in b]
                assert all(0<=y['cyc']-x['cyc']<=1 for x,y in zip(a,b))
        return rows
    result=dict(passed=False,errors=[],measurements=[],canonical_gate=False,standard_suite=False,
                physical_board=False,gameplay_ipc=None)
    begin=time.monotonic()
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures=[pool.submit(case,f,r) for f in range(4) for r in (0,1)]
        for f in futures:
            try: result['measurements'].extend(f.result())
            except BaseException as error: result['errors'].append(repr(error))
    result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-begin)
    result['passed']=not result['errors'] and result['pins_unchanged'] and len(result['measurements'])==128
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
