#!/usr/bin/env python3
"""Four-state check of actual buffered substitutions; never a full-core pass."""
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
import time

import prepare_buffered_integration as buffered

HERE=Path(__file__).resolve().parent


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def save(p,data):
    with p.open('x') as f:json.dump(data,f,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    root=args.out.resolve();parent=args.parent.resolve(strict=True)
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert shutil.disk_usage(scratch).free>2*1024**3
    invocation=os.environ['INVOCATION_ID'];assert re.fullmatch('[0-9a-f]{32}',invocation)
    prior=json.loads((parent/'started.json').read_text())
    closed=json.loads((parent/'closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged']
    pins={**prior['pins'],**prior['generated']}
    for p in (parent/'started.json',parent/'closed.json',Path(__file__).resolve(),
              HERE/'prepare_buffered_integration.py',HERE/'prepare_integration.py'):
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    source=(parent/'core.sv').read_text();candidate=buffered.transform(source)
    root.mkdir()
    (root/'core.sv').write_text(candidate)
    for name in ('ic_residency_reference.svh','ic_front_residency.svh','core_ic_residency_span.svh'):
        shutil.copyfile(parent/name,root/name)
    # Recover every actual new/old expression line from the prepared source.
    # The non-lookup text must match byte-for-byte; it is not reimplemented in
    # this leaf. Evaluate all five distinct lookup expressions in the existing
    # exhaustive/unknown-input stimulus, including both independent lengths.
    blocks=re.findall(r'`ifdef '+buffered.FLAG+r'\n([^`]*?)`else\n([^`]*?)`endif\n',candidate)
    actual=[(old,new) for new,old in blocks if 'ic_buffered(' in old]
    assert len(actual)==15
    pairs=set()
    for old,new in actual:
        skeleton=old
        found=[]
        for raw,factored,_ in buffered.REPLACEMENTS:
            if raw in old:
                assert old.count(raw)==1
                skeleton=skeleton.replace(raw,factored)
                found.append((raw,factored))
        assert len(found)==1 and skeleton==new
        pairs.update(found)
    assert len(pairs)==5
    tb=(parent/'tb_integrated.sv').read_text()
    anchor='  task automatic check_callers;'
    start=tb.index(anchor);end=tb.index('  endtask',start)
    oldtail='    end\n'
    position=tb.rfind(oldtail,start,end)
    assert position>start
    extra=[]
    for i,(raw,factored) in enumerate(sorted(pairs)):
        for old,new in (('sfetch_short_len_q','v_d.len'),('d_len','u_d.len')):
            raw=raw.replace(old,new);factored=factored.replace(old,new)
        extra.append(f'      check_bit({factored},{raw},"actual-buffered-call-{i}");\n')
    tb=tb[:position]+''.join(extra)+tb[position:]
    (root/'tb_buffered.sv').write_text(tb)
    generated={str(p):sha(p) for p in root.iterdir() if p.is_file()}
    save(root/'started.json',dict(pins=pins,generated=generated,invocation=invocation,
        actual_substitution_lines=15,distinct_lookup_expressions=5,production_modified=False))

    def one(mode_cpu):
        mode,cpu=mode_cpu
        binary=root/f'variant{mode}.vvp'
        compile_cmd=['taskset','-c',str(cpu),'iverilog','-g2012','-gstrict-ca-eval',
                     '-s','tb_ic_residency_span','-DVEN_IC_BRAM']
        if mode:compile_cmd+=['-DVEN_IC_NO_FETCH_BYPASS']
        compile_cmd+=['-I'+str(root),'-o',str(binary),str(root/'tb_buffered.sv')]
        with (root/f'compile{mode}.log').open('x') as log:
            compiled=subprocess.run(compile_cmd,stdout=log,stderr=subprocess.STDOUT,timeout=30)
        assert compiled.returncode==0
        command=['taskset','-c',str(cpu),'vvp',str(binary)]
        start=time.monotonic()
        with (root/f'run{mode}.log').open('x') as log:
            child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            proc=Path('/proc')/str(child.pid)
            try:
                deadline=time.monotonic()+3
                while (proc/'exe').resolve().name!='vvp':
                    assert child.poll() is None and time.monotonic()<deadline
                    time.sleep(.01)
                native=dict(pid=child.pid,exe=str((proc/'exe').resolve()),
                    affinity=sorted(os.sched_getaffinity(child.pid)),
                    cgroup=(proc/'cgroup').read_text(),
                    argv=(proc/'cmdline').read_bytes().rstrip(b'\0').decode().split('\0'),
                    starttime=int((proc/'stat').read_text().rsplit(')',1)[1].split()[19]))
                assert native['affinity']==[cpu]
                assert native['cgroup']==Path('/proc/self/cgroup').read_text()
                save(root/f'native{mode}.json',native)
                rc=child.wait(timeout=180)
            finally:
                if child.poll() is None:
                    os.killpg(child.pid,signal.SIGTERM)
                    try:child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid,signal.SIGKILL);child.wait()
        text=(root/f'run{mode}.log').read_text()
        expected=f'IC-RESIDENCY-PROPOSAL-OK no_bypass={mode} checks=9962240'
        return dict(mode=mode,cpu=cpu,compile=compile_cmd,command=command,native=native,
            native_exit=rc,passed=rc==0 and text.count(expected)==1 and not proc.exists(),
            seconds=time.monotonic()-start,log_sha256=sha(root/f'run{mode}.log'))

    error,rows=None,[]
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:rows=list(pool.map(one,[(0,15),(1,16)]))
    except BaseException as exc:error=repr(exc)
    stable=all(sha(p)==h for p,h in {**pins,**generated}.items())
    cg=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    events=dict(line.split() for line in (cg/'memory.events').read_text().splitlines())
    result=dict(passed=error is None and stable and len(rows)==2 and all(x['passed'] for x in rows)
                and events['oom']==events['oom_kill']=='0',error=error,rows=rows,
        inputs_unchanged=stable,memory_events=events,invocation=invocation,
        full_core=False,physical_board=False,standard_suite=False,gameplay_ipc=None,
        limitation='Settled helper identity and unchanged guard syntax; not full-core wiring or fixed-address event sensitivity.')
    save(root/'closed.json',result);print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
