"""Denied-access and page-crossing SMSW witnesses; full unmodified QEMU diff.

The handler inspects original state and memory BEFORE any fault repair. Cache
is on, AXI latency is seven cycles, and virtual pages map to nonadjacent frames.
No register/memory injection, record filtering, added masks or RTL compilation.
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

from run_probe import HERE, REPO, EXTERNAL, QEMU, sha
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt


def save(path, value):
    with path.open('x') as stream:
        json.dump(value,stream,indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',required=True,type=Path)
    ap.add_argument('--core',required=True,type=Path)
    args = ap.parse_args()
    root,core = args.out.resolve(),args.core.resolve(strict=True)
    model = core/'obj/tb_ventium'
    assert __debug__ and root.is_relative_to(EXTERNAL) and root != EXTERNAL and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == EXTERNAL
    assert shutil.disk_usage(EXTERNAL).free > 4*1024**3+256*1024**2
    before,built = [json.loads((core/file).read_text()) for file in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(model) == built['binary_sha256']
    assert len(before['definitions']) == 152 and all(sha(p)==h for p,h in before['pins'].items())
    pins = {str(p):sha(p) for p in (Path(__file__),HERE/'run_probe.py',HERE/'fault.S',HERE/'fault.ld',
        QEMU,model,core/'build-started.json',core/'build-closed.json',
        REPO/'verif/qemu-trace/gen_trace.py',REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py')}
    cpus = sorted(os.sched_getaffinity(0))
    assert len(cpus) == 8
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_','TB_','AXI_','QEMU_'))}
    env.update(AXI_RLAT='7',AXI_WLAT='7',PYTHONDONTWRITEBYTECODE='1')
    cases = [dict(CASE=n,ADDR32=a,OP32=o,CONTROL=0) for n,a,o in itertools.product(range(9),(0,1),(0,1))]
    cases += [dict(CASE=n,ADDR32=1,OP32=0,CONTROL=1) for n in range(9)]
    root.mkdir()
    for path in (Path(__file__),HERE/'fault.S',HERE/'fault.ld'):
        shutil.copyfile(path,root/path.name)
    save(root/'started.json',dict(pins=pins,cases=cases,invocation=os.environ.get('INVOCATION_ID'),
        affinity=cpus,definitions=before['definitions'],model_sha256=sha(model)))

    def case_run(index,c):
        name = '-'.join(k.lower()+str(v) for k,v in c.items())
        folder = root/name
        folder.mkdir()
        pair = cpus[(index%4)*2:(index%4)*2+2]
        def run(label,command,leaf=None):
            actual = ['taskset','-c',','.join(map(str,pair)),'timeout','--kill-after=2s','20s',*map(str,command)]
            save(folder/(label+'-command.json'),dict(argv=actual))
            observed = {}
            with (folder/(label+'.log')).open('x') as log:
                child = subprocess.Popen(actual,env=env,stdout=log,stderr=subprocess.STDOUT)
                try:
                    while child.poll() is None:
                        if leaf:
                            queue = [child.pid]
                            while queue:
                                pid = queue.pop()
                                try:
                                    proc = Path('/proc')/str(pid)
                                    queue.extend(map(int,(proc/'task'/str(pid)/'children').read_text().split()))
                                    if (proc/'exe').readlink().name == leaf:
                                        seen = sorted(os.sched_getaffinity(pid))
                                        assert seen == pair,(name,pid,seen,pair)
                                        observed[pid] = seen
                                except (FileNotFoundError,ProcessLookupError):
                                    pass
                        time.sleep(.002)
                    code = child.wait()
                finally:
                    if child.poll() is None:
                        child.terminate()
                        child.wait(timeout=5)
            save(folder/(label+'-native.json'),dict(exit=code,observed_affinity=observed))
            assert not leaf or observed,(name,label,'native affinity unobserved')
            return code
        obj,elf,image = [folder/('probe'+suffix) for suffix in ('.o','.elf','.bin')]
        assert run('assemble',['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
            *[f'-D{k}={v}' for k,v in c.items()],'-c',HERE/'fault.S','-o',obj]) == 0
        assert run('link',['ld','-m','elf_i386','-T',HERE/'fault.ld','--build-id=none',obj,'-o',elf]) == 0
        assert run('binary',['objcopy','-O','binary',elf,image]) == 0
        assert image.stat().st_size == 65536
        native = run('qemu-native',[QEMU,'-display','none','-monitor','none','-serial','none','-no-reboot',
            '-machine','pc','-cpu','pentium','-m','32','-device','isa-debug-exit,iobase=0xf4,iosize=0x04',
            '-bios',image],leaf=QEMU.name)
        golden = run('golden',['python3',REPO/'verif/qemu-trace/gen_trace.py','--system','--qemu',QEMU,
            '--cpu','pentium','--image',image,'--image-mode','bios','--max-insn','3000',
            '--port',str(12650+index),'--out',folder/'golden.vtrace'],leaf=QEMU.name)
        candidate = run('candidate',[model,'--system','--cosim','--cycle-func','--l1-axi','--image',image,
            '--out',folder/'candidate.vtrace','--max-insn','3000','--max-cycles','1000000',
            '--quiesce','4096','+ven_faultlog','+ven_seglog'],leaf=model.name)
        compare = run('compare',['python3',REPO/'verif/diff/compare.py','--mode','func',
            folder/'golden.vtrace',folder/'candidate.vtrace'])
        faults = [s for s in (folder/'candidate.log').read_text().splitlines() if s.startswith('[FAULT] vec=')]
        expected = None if c['CASE']==8 else (6 if c['CASE']==0 else 13 if c['CASE']<=3 else 14)
        fault_ok = not faults if expected is None else len(faults)==1 and faults[0].startswith(f'[FAULT] vec={expected} ')
        trace = tracefmt.read_trace(str(folder/'candidate.vtrace'))
        passed = native==133 and golden==0 and candidate==133 and compare==0 and fault_ok
        passed &= trace.sys and trace.mode=='func' and int(trace.records[-1]['eax'],16)&255==0x42
        row = dict(case=c,name=name,passed=passed,qemu_native_exit=native,golden_exit=golden,
            rtl_native_exit=candidate,compare_exit=compare,faults=faults,records=len(trace.records),
            artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()})
        save(folder/'closed.json',row)
        return row

    begin = time.monotonic()
    result = dict(passed=False,rows=[],errors=[],standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        jobs = {pool.submit(case_run,index,c):c for index,c in enumerate(cases)}
        for job in concurrent.futures.as_completed(jobs):
            try:
                result['rows'].append(job.result())
            except Exception as error:
                result['errors'].append(dict(case=jobs[job],error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                  records=sum(row['records'] for row in result['rows']))
    result['passed'] = len(result['rows'])==45 and all(row['passed'] for row in result['rows']) and not result['errors'] and result['pins_unchanged']
    save(root/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    print('cases',len(result['rows']),'passed',sum(row['passed'] for row in result['rows']),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
