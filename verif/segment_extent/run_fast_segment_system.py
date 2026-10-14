"""Cold UV-fast system controls at three AXI delays, with exact parent replay.

Run existing generic DS/SS, bounded, relocated, store-fault/retry and invalid-SS
fixtures. No guest patches, snapshots, single stepping or slow-mode acceptance.
The invalid-SS fixture uses its original Intel-spec witnesses, not QEMU's
permissive segment-limit implementation. Other fixtures compare full QEMU state.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import traceback

import prepare_fast_segment as recipe
from run_leaf import sha

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import compare
import tracefmt


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','core','out'): ap.add_argument('--'+name,type=Path,required=True)
    a=ap.parse_args(); parent=a.parent.resolve(strict=True); core=a.core.resolve(strict=True); out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    assert os.sched_getaffinity(0)==set(range(17,21))
    started=json.loads((core/'build-started.json').read_text())
    built=json.loads((core/'build-closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert started['parent_model']==sha(parent/'obj/tb_ventium')=='139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'
    assert built['binary_sha256']==sha(core/'obj/tb_ventium')=='1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c'
    assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()
    assert {'VEN_SEG_ENFORCE','VEN_SYS_FASTLOAD_BOUNDED','VEN_SYS_FASTSTORE_FLAT','VEN_SYS_FASTPATH_RELOC'} <= set(started['definitions'])
    pins=dict(started['pins'])
    assert all(sha(p)==h for p,h in pins.items())
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    gen=REPO/'verif/qemu-trace/gen_trace.py'
    for p in (Path(__file__),Path(recipe.__file__),Path(compare.__file__),Path(tracefmt.__file__),
              core/'obj/tb_ventium',core/'build-closed.json',parent/'obj/tb_ventium',qemu,gen):
        pins[str(p)]=sha(p)
    specs=[('psysfpbounded','psysfpbounded/psysfpbounded.S','psysfpbounded/psysfpbounded.ld',[],3000),
           ('psysfpload','psysfpload/psysfpload.S','psysfpload/psysfpload.ld',[],7000),
           ('psysfpreloc','psysfpreloc/psysfpreloc.S','psysfpreloc/psysfpreloc.ld',[],1000),
           ('pfaststore','pfault/pfault.S','pfault/pfault.ld',['-DFASTSTORE_PROBE'],1400),
           ('pfaststack_segenf','pfaststack/pfaststack.S','pfault/pfault.ld',['-DPFASTSTACK_SEGENF'],1200)]
    for _,asm,ld,_,_ in specs:
        for name in (asm,ld):
            p=REPO/'verif/sys/tests'/name; pins[str(p)]=sha(p)
    out.mkdir()
    def save(path,value):
        with path.open('x') as f: json.dump(value,f,indent=2)
    save(out/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],specs=specs))
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(out),PYTHONDONTWRITEBYTECODE='1')
    def native(cmd,log,limit,extra=None,observe=None,expected=0):
        begin=time.monotonic(); seen=False
        with log.open('x') as stream:
            p=subprocess.Popen(list(map(str,cmd)),stdout=stream,stderr=subprocess.STDOUT,
                env=env | (extra or {}),start_new_session=True)
            try:
                while p.poll() is None:
                    if time.monotonic()-begin>limit: raise subprocess.TimeoutExpired(cmd,limit)
                    if observe:
                        try:
                            if Path('/proc',str(p.pid),'exe').resolve(strict=True)==observe[0]:
                                assert os.sched_getaffinity(p.pid)=={observe[1]}
                                seen=True
                        except (ProcessLookupError,FileNotFoundError): pass
                    time.sleep(.002)
                code=p.wait()
            except BaseException:
                os.killpg(p.pid,signal.SIGTERM)
                try: p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(p.pid,signal.SIGKILL); p.wait()
                raise
        receipt=dict(command=list(map(str,cmd)),native_exit=code,actual_wait=True,
            affinity_observed=seen,seconds=time.monotonic()-begin,log_sha256=sha(log))
        save(log.with_suffix('.closed.json'),receipt)
        assert code==expected and (not observe or seen),receipt
        return receipt
    def run(index_spec):
        index,(name,asm,ld,defs,count)=index_spec; folder=out/name; folder.mkdir()
        cflags=['-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie','-Wall',*defs]
        cpu=17+index%4
        native(['taskset','-c',str(cpu),'gcc',*cflags,'-c',REPO/'verif/sys/tests'/asm,'-o',folder/'test.o'],folder/'assemble.log',20)
        native(['taskset','-c',str(cpu),'gcc',*cflags,'-static','-no-pie','-nostdlib',
                '-Wl,-T,'+str(REPO/'verif/sys/tests'/ld),'-Wl,--build-id=none',folder/'test.o','-o',folder/'test.elf'],folder/'link.log',20)
        native(['objcopy','-O','binary',folder/'test.elf',folder/'test.bin'],folder/'binary.log',10)
        assert (folder/'test.bin').stat().st_size<=65536
        with (folder/'test.bin').open('r+b') as f: f.truncate(65536)
        if name!='pfaststack_segenf':
            native(['taskset','-c',str(cpu),sys.executable,'-B',gen,'--qemu',qemu,'--cpu','pentium','--system',
                    '--image',folder/'test.bin','--image-mode','bios','--out',folder/'gold.vtrace',
                    '--max-insn',str(count),'--port',str(41660+index)],folder/'gold.log',90)
        rows=[]
        for latency in (0,7,31):
            traces={}; counts={}
            for label,model in [('parent',parent/'obj/tb_ventium'),('candidate',core/'obj/tb_ventium')]:
                prefix=label+'-lat'+str(latency); trace=folder/(prefix+'.vtrace'); log=folder/(prefix+'.log')
                receipt=native(['taskset','-c',str(cpu),model,'--system','--cosim','--cycle-func','--l1-axi',
                    '--image',folder/'test.bin','--out',trace,'--max-insn',str(count),
                    '--max-cycles','2000000','--quiesce','4096',
                    '+ven_faultlog'],log,60,dict(AXI_RLAT=str(latency),AXI_WLAT=str(latency)),(model,cpu),133)
                text=log.read_text()
                # Explicit --quiesce suppresses the optional default-selection
                # banner; prove real backing traffic instead of requiring it.
                backing=re.findall(r'^\[L1DPERF\] fill cycles=\d+ backing-wait=\d+ backing-ack=(\d+)$',text,re.M)
                assert len(backing)==1 and int(backing[0])>0,(name,'no L1 backing traffic')
                assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED',text)
                records=tracefmt.read_trace(str(trace)).records; assert records
                final=records[-1]
                assert int(final['eax'],0)&255==0x42,(name,final)
                if name=='pfaststack_segenf':
                    for key,value in dict(edi=0x1f,esi=0x401004,ebx=0xdeadc0de,ebp=0x403100,
                                          edx=0xc0de00f4,cs=8,ss=16).items():
                        assert int(final[key],0)==value,(name,key,final[key])
                    faults=re.findall(r'^\[FAULT\] vec=(\d+).*?err=([0-9a-f]+)',text,re.M)
                    assert sorted(faults)==sorted([('14','00000007'),('14','00000004'),
                        ('14','00000004'),('12','00000000'),('12','00000000')]),faults
                else:
                    # Keep comparator output per execution; no masking or PC-only diff.
                    with (folder/(prefix+'.diff.log')).open('x') as stream:
                        native_cmp=subprocess.run([sys.executable,'-B',REPO/'verif/diff/compare.py',
                            '--mode','func','--all',folder/'gold.vtrace',trace],stdout=stream,
                            stderr=subprocess.STDOUT,env=env,timeout=20)
                    assert native_cmp.returncode==0,(name,prefix,'QEMU difference')
                if name=='psysfpbounded':
                    assert int(final['edi'],0)==0x13579bdf and int(final['ecx'],0)==0
                if name=='pfaststore':
                    for key,value in dict(ecx=3,edx=0x4000f4,edi=3,esi=0xcafebabe).items():
                        assert int(final[key],0)==value,(key,final[key])
                counts[label]=dict(clocks=int(re.search(r'^  clocks\s+(\d+)',text,re.M)[1]),
                    v=int(re.search(r'pairedV=(\d+)',text)[1]),
                    issue=int(re.search(r'^\s*\[\s*12\]\s+(\d+)\s+[\d.]+%\s+ISSUE',text,re.M)[1]),
                    backing_acks=int(backing[0]))
                traces[label]=records
                rows.append(dict(label=label,latency=latency,records=len(records),counts=counts[label],
                    native=receipt,trace_sha256=sha(trace)))
            assert traces['parent']==traces['candidate'] and counts['parent']==counts['candidate']
        assert sum(r['counts']['v'] for r in rows)>0,(name,'no paired execution')
        if name in ('psysfpbounded','psysfpload','pfaststore'):
            assert min(r['counts']['issue'] for r in rows)>=120,(name,'no fast issue')
        result=dict(name=name,passed=True,rows=rows,image_sha256=sha(folder/'test.bin'))
        save(folder/'closed.json',result)
        return result
    begin=time.monotonic(); rows=[]; errors=[]
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures=[(s[0],pool.submit(run,(i,s))) for i,s in enumerate(specs)]
        for name,f in futures:
            try: rows.append(f.result())
            except Exception as error: errors.append(dict(name=name,error=repr(error),traceback=traceback.format_exc()))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=stable and len(rows)==5 and not errors,rows=rows,errors=errors,
        pins_unchanged=stable,seconds=time.monotonic()-begin,standard_suite=False,
        hardware_acceptance=False,gameplay_ipc=None)
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'},indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__': raise SystemExit(main())
