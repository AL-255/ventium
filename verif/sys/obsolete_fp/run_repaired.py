"""Four-worker cold native and full-system-trace tests for obsolete x87.

The basic phase reuses immutable missing-opcode images; state adds protected
mode, full saved-state preservation, pending exceptions and LOCK controls.
Oracle disagreements stay failures, never selectively trimmed/masked.
"""
import argparse
import concurrent.futures
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback

from run_probe import HERE, REPO, sha


def save(path, value):
    with path.open('x') as stream: json.dump(value, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=('basic','state'), required=True)
    for name in ('core','out'): parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--witness',type=Path)
    args = parser.parse_args()
    core, root = args.core.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert os.sched_getaffinity(0)==set(range(8,16)) and os.environ.get('INVOCATION_ID')
    assert shutil.disk_usage(scratch).free>4*1024**3+256*1024**2
    model = core/'obj/tb_ventium'
    before, built = [json.loads((core/n).read_text()) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and sha(model)==built['binary_sha256']
    assert len(before['definitions'])==152 and all(sha(p)==h for p,h in before['pins'].items())
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    assert sha(qemu)=='b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd'
    source = REPO/'verif/qemu-trace/gen_trace.py'; compare = REPO/'verif/diff/compare.py'
    pins = {str(p):sha(p) for p in (Path(__file__),HERE/'run_probe.py',HERE/'state.S',HERE/'state.ld',
        model,qemu,source,compare,REPO/'verif/diff/tracefmt.py',core/'build-started.json',core/'build-closed.json')}
    sys.path.insert(0,str(REPO/'verif/diff')); import tracefmt
    if args.phase=='basic':
        assert args.witness
        witness=args.witness.resolve(strict=True)
        old=json.loads((witness/'closed.json').read_text())
        assert old['passed'] and len(old['rows'])==32 and not old['repaired_rtl']
        pins[str(witness/'closed.json')]=sha(witness/'closed.json')
        cases=[]
        for row in old['rows']:
            c=dict(row['case']);n=f'o{c["OPCODE"]:x}-b{c["BITS"]:x}-p{c["PREFIX"]}-c{c["CONTROL"]}'
            image=witness/(n+'.bin');assert sha(image)==row['image_sha256']
            pins[str(image)]=sha(image);cases.append(dict(defines=c,image=str(image),name=n))
    else:
        defs=[dict(OPCODE=o,PENDING=p,PREFIX=x,LOCKED=0,CONTROL=0)
              for o,p,x in itertools.product((0xe0,0xe1,0xe4),(0,1),(0,1))]
        defs += [dict(OPCODE=0,PENDING=p,PREFIX=x,LOCKED=0,CONTROL=1)
                 for p,x in itertools.product((0,1),(0,1))]
        defs += [dict(OPCODE=0,PENDING=1,PREFIX=x,LOCKED=0,CONTROL=2) for x in (0,1)]
        defs += [dict(OPCODE=o,PENDING=0,PREFIX=x,LOCKED=1,CONTROL=0)
                 for o,x in itertools.product((0xe0,0xe1,0xe4),(0,1))]
        cases=[dict(defines=c,image=None,name='-'.join(k.lower()+str(v) for k,v in c.items())) for c in defs]
    root.mkdir()
    save(root/'started.json',dict(pins=pins,cases=cases,phase=args.phase,invocation=os.environ['INVOCATION_ID'],
        definitions=before['definitions'],affinity=list(range(8,16)),model_sha256=sha(model),x87_trace=False))
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_','TB_','AXI_','QEMU_'))}
    env.update(AXI_RLAT='7',AXI_WLAT='7',PYTHONDONTWRITEBYTECODE='1')

    def case_run(index,case):
        folder=root/case['name'];folder.mkdir();c=case['defines']
        pair=[8+2*(index%4),9+2*(index%4)]
        def run(label,command,leaf=None):
            actual=['taskset','-c',','.join(map(str,pair)),'timeout','--kill-after=2s','20s',*map(str,command)]
            save(folder/(label+'.command.json'),actual)
            observed={}
            with (folder/(label+'.log')).open('x') as log:
                child=subprocess.Popen(actual,env=env,stdout=log,stderr=subprocess.STDOUT)
                try:
                    while child.poll() is None:
                        queue=[child.pid] if leaf else []
                        while queue:
                            pid=queue.pop()
                            try:
                                proc=Path('/proc')/str(pid)
                                queue.extend(map(int,(proc/'task'/str(pid)/'children').read_text().split()))
                                if (proc/'exe').readlink().name==leaf:
                                    seen=sorted(os.sched_getaffinity(pid));assert seen==pair
                                    observed[pid]=seen
                            except (FileNotFoundError,ProcessLookupError):pass
                        time.sleep(.002)
                    code=child.wait()
                finally:
                    if child.poll() is None:child.terminate();child.wait(timeout=5)
            save(folder/(label+'.native.json'),dict(exit=code,observed_affinity=observed))
            assert not leaf or observed,(case['name'],label,'affinity unobserved')
            return code
        if case['image']:
            image=Path(case['image'])
        else:
            obj,elf,image=[folder/('probe'+s) for s in ('.o','.elf','.bin')]
            assert run('assemble',['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
                *[f'-D{k}={v}' for k,v in c.items()],'-c',HERE/'state.S','-o',obj])==0
            assert run('link',['ld','-m','elf_i386','-T',HERE/'state.ld','--build-id=none',obj,'-o',elf])==0
            assert run('binary',['objcopy','-O','binary',elf,image])==0 and image.stat().st_size==65536
        q=run('qemu',[qemu,'-display','none','-monitor','none','-serial','none','-no-reboot',
            '-machine','pc','-cpu','pentium','-m','32','-device','isa-debug-exit,iobase=0xf4,iosize=0x04','-bios',image],qemu.name)
        r=run('rtl',[model,'--system','--cosim','--cycle-func','--l1-axi','--image',image,
            '--out',folder/'rtl.vtrace','--max-insn','3000','--max-cycles','1000000',
            '--quiesce','4096','+ven_faultlog','+ven_seglog'],model.name)
        g=run('golden',['python3',source,'--system','--qemu',qemu,'--cpu','pentium','--image',image,
            '--image-mode','bios','--max-insn','3000','--port',str((14500 if args.phase=='basic' else 14700)+index),
            '--out',folder/'golden.vtrace'],qemu.name)
        d=run('compare',['python3',compare,'--mode','func',folder/'golden.vtrace',folder/'rtl.vtrace'])
        faults=[s for s in (folder/'rtl.log').read_text().splitlines() if s.startswith('[FAULT] vec=')]
        expected=(7 if c['BITS'] else None) if args.phase=='basic' else (6 if c['LOCKED'] else 16 if c['CONTROL']==2 else None)
        fault_ok=not faults if expected is None else len(faults)==1 and faults[0].startswith(f'[FAULT] vec={expected} ')
        trace=tracefmt.read_trace(str(folder/'rtl.vtrace'))
        rtl_ok=r==133 and fault_ok and trace.sys and trace.mode=='func' and 20<len(trace.records)<3000
        rtl_ok &= (int(trace.records[-1]['eax'],16)&255)==0x42
        row=dict(case=c,passed=bool(rtl_ok and q==133 and g==0 and d==0),rtl_self_check=bool(rtl_ok),
            qemu_exit=q,rtl_exit=r,golden_exit=g,compare_exit=d,faults=faults,records=len(trace.records),
            artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()})
        save(folder/'closed.json',row);print(case['name'],'PASS' if row['passed'] else 'FAIL',flush=True)
        return row
    begin=time.monotonic()
    result=dict(passed=False,rows=[],errors=[],canonical_gate_passed=False,standard_suite=False,
                hardware_acceptance=False,gameplay_ipc=None)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures={pool.submit(case_run,i,c):c for i,c in enumerate(cases)}
        for future in concurrent.futures.as_completed(futures):
            try:result['rows'].append(future.result())
            except Exception as error:result['errors'].append(dict(case=futures[future],error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed']=len(result['rows'])==len(cases) and all(r['passed'] for r in result['rows']) and not result['errors'] and result['pins_unchanged']
    save(root/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    print('cases',len(result['rows']),'differential_pass',sum(r['passed'] for r in result['rows']),
          'rtl_self_check',sum(r['rtl_self_check'] for r in result['rows']),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
