"""Unchanged 108-program functional worker, isolated qualified private oracle.

Never replaces canonical QEMU, changes a mask/band, trims a trace, or counts
this private functional result as the complete canonical/standard-suite gate.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse
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

REPO=Path(__file__).resolve().parents[3]


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def save(p,v):
    with p.open('x') as f:
        json.dump(v,f,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('build','probe','core','out'):
        ap.add_argument('--'+name,type=Path,required=True)
    a=ap.parse_args(); root=a.out.resolve(); core=a.core.resolve(strict=True)
    build=a.build.resolve(strict=True); probe=a.probe.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.sched_getaffinity(0)==set(range(8,12))
    assert os.environ['INVOCATION_ID'] and shutil.disk_usage(scratch).free>4*1024**3+100*1024**2
    built=json.loads((build/'closed.json').read_text())
    tested=json.loads((probe/'closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and tested['passed'] and tested['pins_unchanged']
    qemu=Path(built['binary']); model=core/'obj/tb_ventium'
    assert sha(qemu)==built['sha256']
    assert sha(model)=='369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150'
    pins=dict(json.loads((core/'build-started.json').read_text())['pins'])
    pins.update(json.loads((probe/'started.json').read_text())['pins'])
    actual=(core/'obj/Vventium_top__verFiles.dat').read_text()
    macros=set(re.findall(r'\+define\+(\w+)',actual))
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_PIPE_SDISPATCH','VEN_L1D_CODE_PAYLOAD_SELECT'}<=macros
    jobs_file=core/'generic-work/jobs.txt'
    jobs=[line.split('\t') for line in jobs_file.read_text().splitlines() if line.startswith('func\t')]
    assert len(jobs)==len({j[1] for j in jobs})==108
    for job in jobs:
        assert len(job)==10
        manifest=Path(job[2]).parent/'manifest.json'
        assert str(json.loads(manifest.read_text())['max_insn'])==job[5]
        for p in (Path(job[2]),manifest): pins[str(p)]=sha(p)
    worker=REPO/'verif/lib/verify_worker.sh'
    refs=REPO/'ventium-refs/07-p5-emulation-harness'
    for p in (Path(__file__),model,qemu,jobs_file,build/'closed.json',probe/'closed.json',worker,
              REPO/'verif/tests/elf2flat.py',REPO/'build/p5trace.so',refs/'tools/isa_verify.py',
              REPO/'verif/m5_metrics.py',REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py'):
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    root.mkdir(); work=root/'work'; work.mkdir(); cache=root/'private-enabled-cache'; cache.mkdir()
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_','VERIFY_'))}
    env.update(TMPDIR=str(root),PYTHONDONTWRITEBYTECODE='1',QEMU=str(qemu),VTM_QEMU_GDB_PREEXIT='1',
        ISA_VERIFY=str(refs/'tools/isa_verify.py'),GEN_TRACE=str(REPO/'verif/qemu-trace/gen_trace.py'),
        COMPARE=str(REPO/'verif/diff/compare.py'),ELF2FLAT=str(REPO/'verif/tests/elf2flat.py'),
        P5TRACE=str(REPO/'build/p5trace.so'),TB_BIN=str(model),M5_METRICS=str(REPO/'verif/m5_metrics.py'),
        PYTHON='/usr/bin/python3',CC='/usr/bin/gcc',
        CFLAGS_BASE='-m32 -march=pentium -nostdlib -static -Wl,--build-id=none',
        WORKDIR=str(work),CACHE_DIR=str(cache),PORTBASE='41300',M5_TOL_PCT='10',
        TB_EXTRA_FLAGS='--cycle-func --l1-axi',TB_CYCLE_EXTRA_FLAGS='--l1-axi',AXI_RLAT='7',AXI_WLAT='7')
    save(root/'started.json',dict(pins=pins,jobs=jobs,invocation=os.environ['INVOCATION_ID'],
        model=sha(model),oracle=sha(qemu),workers=4,environment={k:v for k,v in env.items() if k in
        ('QEMU','VTM_QEMU_GDB_PREEXIT','TB_BIN','TB_EXTRA_FLAGS','AXI_RLAT','AXI_WLAT','CACHE_DIR')}))
    def run(index_job):
        index,job=index_job; name=job[1]; cpu=8+index%4
        command=['taskset','-c',str(cpu),'bash',str(worker),*job[:9]]
        seen={}; began=time.monotonic(); error=None
        with (work/(name+'.worker.log')).open('x') as log:
            child=subprocess.Popen(command,cwd=REPO,env=dict(env,KCLASS=job[9]),
                stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            try:
                while child.poll() is None:
                    if time.monotonic()-began>120: raise subprocess.TimeoutExpired(command,120)
                    queue=[child.pid]
                    while queue:
                        pid=queue.pop()
                        try:
                            proc=Path('/proc')/str(pid)
                            queue.extend(map(int,(proc/'task'/str(pid)/'children').read_text().split()))
                            name_exe=(proc/'exe').readlink().name
                            if name_exe in ('tb_ventium','qemu-i386'):
                                affinity=sorted(os.sched_getaffinity(pid))
                                assert affinity==[cpu]
                                seen[pid]=dict(executable=name_exe,affinity=affinity)
                        except (FileNotFoundError,ProcessLookupError):
                            pass
                    time.sleep(.001)
                code=child.wait()
            except BaseException as exc:
                error=repr(exc)
                os.killpg(child.pid,signal.SIGTERM)
                try: code=child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid,signal.SIGKILL); code=child.wait()
        f=work/(name+'.func.result'); result=f.read_text().strip() if f.exists() else ''
        fields=result.split('|')
        affinity_ok={v['executable'] for v in seen.values()}=={'tb_ventium','qemu-i386'}
        passed=error is None and code==0 and fields[:2]==['FUNC',name] and fields[3]=='PASS' and affinity_ok
        row=dict(name=name,command=command,native_worker_exit=code,actual_wait=True,
            result=result,passed=passed,error=error,seconds=time.monotonic()-began,
            observed_affinity=seen,affinity_verified=affinity_ok)
        save(work/(name+'.closure.json'),row)
        return row
    begin=time.monotonic()
    with ThreadPoolExecutor(max_workers=4) as pool:
        rows=list(pool.map(run,enumerate(jobs)))
    stable=all(sha(p)==h for p,h in pins.items())
    cg=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    events=dict(line.split() for line in (cg/'memory.events').read_text().splitlines())
    passed=stable and all(r['passed'] for r in rows) and events['oom']==events['oom_kill']=='0'
    result=dict(passed=passed,rows=rows,pins_unchanged=stable,seconds=time.monotonic()-begin,
        memory_events=events,canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    save(root/'closed.json',result)
    print(json.dumps({**result,'rows':[r for r in rows if not r['passed']]},indent=2),flush=True)
    return int(not passed)


if __name__=='__main__':
    raise SystemExit(main())
