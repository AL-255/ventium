"""Cold physical-owner checks in UV-fast + AXI, never slow-mode substitutes.

New real-mode INT/IRET microtest has full QEMU state comparison. Existing SMM
tests retain their original P5 witnesses (QEMU single-step cannot observe SMI).
This does not claim the separate prsmflush invalidation-contract gate or a
complete system suite. Every parent/candidate trace and clock count must match.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import textwrap
import time
import traceback

import run_early_bus_checks as identity
import run_probe_boundary_ab as boundary

REPO = Path(__file__).resolve().parents[2]
tracefmt, compare, native, sha = boundary.tracefmt, boundary.compare, boundary.native, boundary.sha
SMCHECK = REPO/'verif/sys/tests/psmm/psmm-rtl-selfcheck.py'


def grade(name, records, dump):
    h = lambda key: int(records[-1][key],0)
    assert h('eax') & 255 == 0x42
    if name == 'real-int':
        assert h('edi') == 0x524d4952 and h('esi') == 2 and h('ebx') == 128 and h('esp') == 0x7000
        assert any(int(r['cs'],0)==0xf000 for r in records) and h('cs')==8
    elif name == 'psmmmeta':
        for key,value in dict(edi=0x42,esi=5,ebx=0x5aa30003,ebp=0x5aa20002,ecx=2).items():
            assert h(key)==value,(key,h(key),value)
        assert h('edx')>>16 == 0x600d and len(records)>40000
    else:
        # Execute the complete existing trace + P5 memory-map witness body,
        # with retained evidence rather than its old temporary runner/exit bug.
        source = SMCHECK.read_text()
        first = source.index('    # ---- (1) trace-record evidence')
        last = source.index('\nif fails:')
        body = textwrap.dedent(source[first:last])
        failures, checks = [], []
        def check(label, condition, detail):
            checks.append(label)
            if not condition: failures.append((label,detail))
        namespace = dict(json=json,SMBASE=0x30000,trace=str(dump.with_suffix('.vtrace')),
                         dump=str(dump),check=check)
        exec(compile(body,str(SMCHECK),'exec'),namespace)
        assert len(checks)==18 and not failures,failures


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','core','out'): ap.add_argument('--'+name,type=Path,required=True)
    a=ap.parse_args(); parent,core=a.parent.resolve(strict=True),a.core.resolve(strict=True); out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    assert os.sched_getaffinity(0)==set(range(17,21)) and os.environ['INVOCATION_ID']
    before=json.loads((core/'build-started.json').read_text()); built=json.loads((core/'build-closed.json').read_text())
    assert built['passed'] and built['binary_sha256']==sha(core/'obj/tb_ventium')==identity.MODEL
    assert before['parent_model']==sha(parent/'obj/tb_ventium')==identity.builder.MODEL
    assert identity.recipe.transform((parent/'candidate'/identity.recipe.FILE).read_text())==(core/'candidate'/identity.recipe.FILE).read_text()
    assert {'VEN_SEG_ENFORCE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_L1_AXI'} <= set(before['definitions'])
    specs=[('real-int',REPO/'verif/fetchguard/t_bus_rm_owners.S',REPO/'verif/sys/tests/pfault/pfault.ld',1000),
           ('psmm',REPO/'verif/sys/tests/psmm/psmm.S',REPO/'verif/sys/tests/psmm/psmm.ld',12000),
           ('psmmmeta',REPO/'verif/sys/tests/psmmmeta/psmmmeta.S',REPO/'verif/sys/tests/psmmmeta/psmmmeta.ld',60000)]
    qemu=boundary.contracts.QEMU
    boundary.contracts.pin(qemu,boundary.contracts.QEMU_SHA)
    pins=dict(before['pins'])
    for p in [Path(__file__),Path(identity.__file__),Path(boundary.__file__),Path(native.__file__),
              Path(compare.__file__),Path(tracefmt.__file__),SMCHECK,qemu,core/'obj/tb_ventium',parent/'obj/tb_ventium',
              *(p for s in specs for p in s[1:3])]: pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    out.mkdir()
    def save(p,v):
        with p.open('x') as stream: json.dump(v,stream,indent=2)
    save(out/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cycle_mode=1,
        debugger_step=False,snapshots=False,candidate=identity.MODEL))
    begin=time.monotonic(); rows=[]; errors=[]
    def run(folder,label,cmd,expected=0):
        receipt=native.supervise(list(map(str,cmd)),folder/(label+'.stdout'),folder/(label+'.stderr'),
                                folder/(label+'.exit.json'),90)
        assert receipt['actual_return_code']==expected and receipt['actual_wait'] and receipt['group_closed'],receipt
        text=(folder/(label+'.stdout')).read_text()+(folder/(label+'.stderr')).read_text()
        assert not native.FATAL.search(text),label
        return text
    def case(item):
        index,(name,asm,ld,limit)=item; folder=out/name; folder.mkdir(); cpu=17+index
        cflags=['-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie','-Wall']
        run(folder,'assemble',['gcc',*cflags,'-c',asm,'-o',folder/'test.o'])
        run(folder,'link',['gcc',*cflags,'-static','-no-pie','-Wl,-T,'+str(ld),'-Wl,--build-id=none',folder/'test.o','-o',folder/'test.elf'])
        run(folder,'binary',['objcopy','-O','binary',folder/'test.elf',folder/'test.bin'])
        assert (folder/'test.bin').stat().st_size<=65536
        subprocess.run(['truncate','-s','65536',folder/'test.bin'],check=True)
        run(folder,'free-qemu',[qemu,'-cpu','pentium','-machine','pc','-m','32','-display','none','-serial','none',
            '-monitor','none','-no-reboot','-no-shutdown','-device','isa-debug-exit,iobase=0xf4,iosize=0x04',
            '-bios',folder/'test.bin'],133)
        if name=='real-int':
            run(folder,'golden',[sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,
                '--cpu','pentium','--system','--image',folder/'test.bin','--image-mode','bios',
                '--max-insn',str(limit),'--port','42601','--out',folder/'gold.vtrace'])
        results=[]
        for latency in (0,7,31):
            both={}; counts={}
            for label,model in [('parent',parent/'obj/tb_ventium'),('candidate',core/'obj/tb_ventium')]:
                modes={}; clocks={}
                for mode in ('cycle-func','cycle'):
                    tag=f'{label}-lat{latency}-{mode}'; trace=folder/(tag+'.vtrace'); dump=folder/(tag+'.json')
                    command=['env',f'AXI_RLAT={latency}',f'AXI_WLAT={latency}','taskset','-c',str(cpu),model,
                        '--system','--cosim','--'+mode,'--l1-axi','--image',folder/'test.bin','--out',trace,
                        '--max-insn',str(limit),'--max-cycles','5000000','--quiesce','4096']
                    if name=='psmm': command+=['--smm-dump',dump,'--smbase','0x30000']
                    log=run(folder,tag,command,133)
                    parsed=tracefmt.read_trace(str(trace)); assert 0<len(parsed.records)<limit
                    modes[mode]=parsed.records
                    clocks[mode]=int(re.search(r'after \d+ retired in (\d+) clocks',log)[1])
                    if mode=='cycle-func':
                        grade(name,parsed.records,dump)
                        if name=='real-int':
                            gold=tracefmt.read_trace(str(folder/'gold.vtrace'))
                            with (folder/(tag+'.diff.log')).open('x') as stream:
                                assert compare.compare_func(gold,parsed,False,0xffffffff,False,20,stream,sys_both=True)==0
                assert clocks['cycle']==clocks['cycle-func']
                paired=sum(r.get('pipe')=='V' and r.get('paired') for r in modes['cycle'])
                assert paired>0,(name,label,'no paired retirement')
                both[label]=modes; counts[label]=clocks
                results.append(dict(case=name,label=label,latency=latency,records=len(modes['cycle']),
                                    clocks=clocks['cycle'],paired_v=paired))
            assert both['parent']==both['candidate'] and counts['parent']==counts['candidate']
        return results
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures=[pool.submit(case,item) for item in enumerate(specs)]
        for future in futures:
            try: rows.extend(future.result())
            except Exception as error: errors.append(dict(error=repr(error),traceback=traceback.format_exc()))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=stable and len(rows)==18 and not errors,rows=rows,errors=errors,pins_unchanged=stable,
        seconds=time.monotonic()-begin,canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'},indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__': raise SystemExit(main())
