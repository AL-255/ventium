#!/usr/bin/env python3
"""Cold TF/RF, CPL3 fault/retry and CPU-store SMC; no rebuild or trace filtering."""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
sys.path.insert(0,str(REPO/'verif/diff'))
sys.path.insert(0,str(REPO/'verif/sys'))
import tracefmt
import check_faultlog
spec=importlib.util.spec_from_file_location('native_events',REPO/'verif/sys/run-native-system.py')
native=importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('control','candidate','out'): ap.add_argument('--'+name,type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models={name:getattr(args,name).resolve(strict=True) for name in ('control','candidate')}
    profiles=[]; pins={}
    for model in models.values():
        stamp=model.parent/'Vventium_top__verFiles.dat'
        command=next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
        assert ' --assert ' in command
        defs=set(re.findall(r'\+define\+(\w+)',command))
        assert {'VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_PIPE_SDISPATCH',
                'VEN_PIPE_SDISPATCH_SHORT','VEN_L1_AXI','VEN_SEG_ENFORCE'}<=defs
        assert not {'VEN_SYS_FASTPATH_ALL','VTM_NO_DPI','SYNTHESIS'}&defs
        profiles.append(defs)
        pins.update({str(p):sha(p) for p in (model,stamp)})
    assert profiles[0]==profiles[1]
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    linker=REPO/'verif/sys/tests/ppage/ppage.ld'
    for p in (Path(__file__),HERE/'system-dispatch-debug.S',HERE/'system-dispatch-cpl3.S',
              HERE/'system-dispatch-smc.S',
              linker,qemu,REPO/'verif/qemu-trace/gen_trace.py',REPO/'verif/diff/compare.py',
              REPO/'verif/diff/tracefmt.py',REPO/'verif/sys/run-native-system.py',
              REPO/'verif/sys/check_faultlog.py'): pins[str(p)]=sha(p)
    (args.out/'inputs.json').write_text(json.dumps(pins,indent=2)+'\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(args.out),PYTHONDONTWRITEBYTECODE='1')
    def run(command,leaf,name,expected=0,latency=0):
        command=['timeout','--kill-after=3s','60s',*map(str,command)]
        (leaf/(name+'.command.json')).write_text(json.dumps(command,indent=2)+'\n')
        with (leaf/(name+'.stdout')).open('x') as out,(leaf/(name+'.stderr')).open('x') as err:
            code=subprocess.run(command,env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),
                                stdout=out,stderr=err).returncode
        (leaf/(name+'.exit')).write_text(str(code)+'\n')
        assert code==expected,(name,code,expected)
        return code
    def check(case):
        kind,reloc=case
        leaf=args.out/f'{kind}-r{reloc}'; leaf.mkdir()
        obj,elf,image=[leaf/('fixture.'+ext) for ext in ('o','elf','bin')]
        run(['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',f'-DRELOC={reloc}',f'-DOFFSET={reloc}',
             '-c',HERE/f'system-dispatch-{kind}.S','-o',obj],leaf,'assemble')
        run(['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
             '-Wl,--build-id=none',obj,'-o',elf],leaf,'link')
        run(['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image],leaf,'binary')
        symbols={p[2]:int(p[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                 if len(p:=line.split())==3}
        run([qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,'-display','none',
             '-serial','none','-monitor','none','-no-reboot','-no-shutdown',
             '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],leaf,'free-qemu',133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
        run([sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,'--system',
             '--image',image,'--image-mode','bios','--cpu','pentium','--out',leaf/'golden.vtrace',
             '--max-insn','2000','--port',str(port)],leaf,'golden')
        results=[]
        for latency in (0,7):
            for name,tb in models.items():
                traces={}
                for mode in ('cycle-func','cycle'):
                    stem=f'{name}-lat{latency}-{mode}'; path=leaf/(stem+'.vtrace')
                    rc=run([tb,'--system','--cosim','--'+mode,'--l1-axi','--image',image,
                        '--out',path,'--max-insn','2000','--max-cycles','1000000','--quiesce','4096',
                        '+ven_fetchdbg','+ven_fetchdbg_max=10000','+ven_faultlog'],leaf,stem,133,latency)
                    parsed=tracefmt.read_trace(str(path)); traces[mode]=parsed.records
                    log=(leaf/(stem+'.stdout')).read_text()
                    if mode=='cycle-func':
                        native.grade_native(parsed,log,(leaf/(stem+'.stderr')).read_text(),rc,133,2000)
                        run([sys.executable,'-B',REPO/'verif/diff/compare.py','--mode','func','--all',
                             '--max-report','8',leaf/'golden.vtrace',path],leaf,stem+'-diff')
                rows=traces['cycle']
                assert [x['pc'] for x in rows]==[x['pc'] for x in traces['cycle-func']]
                pairs=[x for x in rows if int(x['pc'],16)==symbols['pair_v'] and x.get('pipe')=='V' and x.get('paired')]
                assert len(pairs)>=6,('missing actual target V pairs',len(pairs))
                target=symbols['hot_read' if kind=='cpl3' else 'hot_op']
                hits=[i for i,x in enumerate(rows) if int(x['pc'],16)==target]
                assert len(hits)==(16 if kind=='smc' else 8)
                offers=[line for line in log.splitlines() if '[FETCHDBG:SDISPATCH] ' in line]
                dispatches=sum(f'eip={target:08x} ' in line for line in offers)
                if kind=='debug':
                    # Trace is post-instruction; the preceding IRETD owns live
                    # issue flags. TF and RF visits must not direct-dispatch.
                    incoming=[int(traces['cycle-func'][i-1]['eflags'],16) for i in hits]
                    assert [(f>>8)&1 for f in incoming]==[0,0,1,0,0,0,0,0],incoming
                    assert [(f>>16)&1 for f in incoming]==[0,0,0,1,0,0,0,0],incoming
                    assert dispatches==(6 if name=='candidate' else 0),dispatches
                    assert sum(int(x['pc'],16)==symbols['db_handler'] for x in rows)==1
                elif kind=='cpl3':
                    assert dispatches==(8 if name=='candidate' else 0),dispatches
                    fault=symbols['fault_op']
                    fault_offers=[line for line in offers if f'eip={fault:08x} ' in line]
                    if name=='candidate':
                        # The faulting attempt MUST use direct dispatch. A
                        # relocated IRET can miss the instruction-line owner
                        # on retry, which correctly uses the normal fetch.
                        assert 1<=len(fault_offers)<=2,fault_offers
                        assert log.index(fault_offers[0]) < log.index('[FAULT] vec=14 ')
                    else:
                        assert not fault_offers,fault_offers
                    assert all('cpl=3 ' in line for line in fault_offers)
                    check_faultlog.check_counts(check_faultlog.read_counts(log.splitlines()),{(14,7):1})
                    # The architectural trace includes the fault-delivery
                    # event as well as the later successful retry. Do not
                    # mistake trace records for hardware retirement pulses.
                    attempts=[i for i,x in enumerate(rows) if int(x['pc'],16)==fault]
                    assert len(attempts)==2,('fault/retry event count',attempts)
                    assert int(rows[attempts[0]+1]['pc'],16)==symbols['pf_handler']
                    assert int(rows[attempts[1]+1]['pc'],16)==symbols['after_fault']
                else:
                    assert len(pairs)==16
                    # Cold/refill visits may lack residency. Both phases must
                    # nevertheless contain genuinely direct-dispatched adds.
                    if name=='candidate':
                        offers_by_phase=log.split('[FETCHDBG:SDISPATCH]')
                        assert dispatches>=14,dispatches
                    else:
                        assert dispatches==0
                    check_faultlog.check_counts(check_faultlog.read_counts(log.splitlines()),{})
                    values=[int(traces['cycle-func'][i]['eax'],16) for i in hits]
                    assert values==[7*n for n in range(1,9)]+[56+9*n for n in range(1,9)],values
                results.append(dict(kind=kind,reloc=reloc,latency=latency,model=name,
                                    paired_v=len(pairs),dispatches=dispatches,full_qemu_diff=True))
        return results
    result=dict(passed=False,gameplay_ipc=None,standard_suite=False,cases=[],errors=[])
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            pending={pool.submit(check,c):c for c in [('debug',0),('cpl3',0),('cpl3',1),('smc',0),('smc',31)]}
            for future in concurrent.futures.as_completed(pending):
                try: result['cases'].extend(future.result())
                except Exception as exc: result['errors'].append(dict(case=pending[future],error=str(exc)))
        result['passed']=not result['errors']
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        (args.out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
    assert result['passed']

if __name__=='__main__': main()
