"""Reproduce native cross-mode stale goldens, then check isolated cache repair.

Runs the real worker, qualified QEMU, unchanged smoke ELF source, current
UV-fast AXI model and comparator. Old false-pass/false-fail witnesses remain.
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

import prepare_preexit_cache as recipe

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/diff'))
import tracefmt


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as f: json.dump(value, f, indent=2)


def run_sequence(spec, root, env, old, fixed):
    name, cpu, repaired, modes = spec
    folder = root/name; folder.mkdir(); cache = folder/'cache'; cache.mkdir()
    rows = []
    for index, mode in enumerate(modes):
        work = folder/str(index); work.mkdir()
        current = dict(env, WORKDIR=str(work), CACHE_DIR=str(cache), PORTBASE=str(42000 + cpu*16))
        current.pop('VTM_QEMU_GDB_PREEXIT', None)
        if mode is not None: current['VTM_QEMU_GDB_PREEXIT'] = mode
        command = ['taskset', '-c', str(cpu), 'bash', str(fixed if repaired else old),
                   'func', 'smoke', str(REPO/'verif/tests/smoke/smoke.s'),
                   '0x08048000', '0x08048000', '22', '0', '0', '-']
        before = {p.name:sha(p) for p in cache.glob('*.vtrace')}
        observed = {}; start = time.monotonic()
        with (work/'worker.log').open('x') as log:
            child = subprocess.Popen(command, cwd=REPO, env=current, stdout=log,
                                     stderr=subprocess.STDOUT, start_new_session=True)
            try:
                while child.poll() is None:
                    assert time.monotonic()-start < 60, 'worker timeout'
                    queue = [child.pid]
                    while queue:
                        pid = queue.pop()
                        try:
                            proc = Path('/proc')/str(pid)
                            queue.extend(map(int, (proc/'task'/str(pid)/'children').read_text().split()))
                            executable = (proc/'exe').readlink().name
                            if executable in ('tb_ventium', 'qemu-i386'):
                                affinity = sorted(os.sched_getaffinity(pid))
                                assert affinity == [cpu]
                                observed[pid] = dict(executable=executable, affinity=affinity)
                        except (FileNotFoundError, ProcessLookupError): pass
                    time.sleep(.001)
                code = child.wait()
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    try: child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL); child.wait()
        assert code == 0 and not (Path('/proc')/str(child.pid)).exists()
        result = (work/'smoke.func.result').read_text().strip().split('|')
        assert result[:3] == ['FUNC', 'smoke', 'int'] and result[3] in ('PASS', 'FAIL')
        hit = result[-1] == '1'
        after = {p.name:sha(p) for p in cache.glob('*.vtrace')}
        assert all(after[n] == h for n, h in before.items())
        assert len(after) == len(before) + int(not hit)
        oracle = next(p for p in cache.glob('*.vtrace') if p.name not in before) if not hit else None
        rtl = tracefmt.read_trace(str(work/'smoke.func_rtl.vtrace'))
        assert len(rtl.records) == 22 and not rtl.x87
        text = (work/'smoke.func_rtl.log').read_text()
        assert '--l1-axi selected' in text and int(re.search(r'pairedV=(\d+)', text)[1]) > 0
        seen = {v['executable'] for v in observed.values()}
        assert 'tb_ventium' in seen and ('qemu-i386' in seen) == (not hit)
        enabled = mode == '1'
        # The old key incorrectly reuses the first observation mode forever.
        effective = enabled if repaired else modes[0] == '1'
        assert result[3] == ('PASS' if effective else 'FAIL')
        if not effective: assert 'LENGTH MISMATCH: A has 21, C has 22' in result[4]
        if oracle is not None:
            golden = tracefmt.read_trace(str(oracle))
            assert len(golden.records) == (22 if enabled else 21)
        assert hit == (index > 0 and (not repaired or enabled in [m == '1' for m in modes[:index]]))
        row = dict(index=index,mode=mode,enabled=enabled,cache_hit=hit,cache_files=after,
            verdict=result[3],detail=result[4],native_worker_exit=code,actual_wait=True,
            observed_affinity=observed,command=command,seconds=time.monotonic()-start)
        rows.append(row); save(work/'closed.json',row)
    expected_entries = 2 if repaired else 1
    assert len(list(cache.glob('*.vtrace'))) == expected_entries
    return dict(name=name, repaired=repaired, passed=True, rows=rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__); ap.add_argument('--out', type=Path, required=True)
    root = ap.parse_args().out.resolve(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and os.sched_getaffinity(0) == set(range(13,17))
    assert os.environ['INVOCATION_ID'] and shutil.disk_usage(scratch).free > 4*1024**3 + 64*1024**2
    old = REPO/'verif/lib/verify_worker.sh'
    text = recipe.transform(old.read_text())
    assert text.replace(recipe.NEW,recipe.OLD) == old.read_text()
    qemu = scratch/'ventium-qemu-frndint.wRXifJwr/build-r1/build/qemu-i386'
    model = scratch/'ventium-data-size.v2HaTO2X/core-r1/obj/tb_ventium'
    assert sha(qemu) == 'da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d'
    assert sha(model) == 'fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041'
    ref = REPO/'ventium-refs/07-p5-emulation-harness'
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_','VERIFY_'))}
    env.update(QEMU=str(qemu), ISA_VERIFY=str(ref/'tools/isa_verify.py'),
        GEN_TRACE=str(REPO/'verif/qemu-trace/gen_trace.py'), COMPARE=str(REPO/'verif/diff/compare.py'),
        ELF2FLAT=str(REPO/'verif/tests/elf2flat.py'), P5TRACE=str(REPO/'build/p5trace.so'),
        TB_BIN=str(model), M5_METRICS=str(REPO/'verif/m5_metrics.py'), PYTHON='/usr/bin/python3', CC='/usr/bin/gcc',
        CFLAGS_BASE='-m32 -march=pentium -nostdlib -static -Wl,--build-id=none',
        M5_TOL_PCT='10',TB_EXTRA_FLAGS='--cycle-func --l1-axi',AXI_RLAT='7',AXI_WLAT='7',TMPDIR=str(root))
    root.mkdir(); fixed = root/'verify_worker.sh'
    with fixed.open('x') as f: f.write(text)
    pins = {str(p):sha(p) for p in (old,fixed,Path(__file__),Path(recipe.__file__),Path(tracefmt.__file__),
        REPO/'verif/tests/smoke/smoke.s',REPO/'verif/tests/smoke/manifest.json',
        model.parent/'Vventium_top__verFiles.dat',*(Path(env[k]) for k in
        ('QEMU','ISA_VERIFY','GEN_TRACE','COMPARE','ELF2FLAT','P5TRACE','TB_BIN','M5_METRICS')))}
    save(root/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],workers=4))
    specs = [('old-off-first',13,False,[None,'1']),('old-on-first',14,False,['1',None]),
             ('fixed-off-first',15,True,[None,'1','0','yes','','1']),
             ('fixed-on-first',16,True,['1',None,'1','01'])]
    rows=[];error=None
    try:
        with ThreadPoolExecutor(max_workers=4) as pool:
            rows=list(pool.map(lambda s:run_sequence(s,root,env,old,fixed),specs))
    except Exception as exc:
        import traceback
        error=dict(error=repr(exc),traceback=traceback.format_exc())
    stable=all(sha(p)==h for p,h in pins.items())
    cg=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    events=dict(r.split() for r in (cg/'memory.events').read_text().splitlines())
    result=dict(passed=error is None and len(rows)==4 and stable and events['oom']==events['oom_kill']=='0',
        rows=rows,error=error,pins_unchanged=stable,memory_events=events,
        canonical_worker_changed=False,oracle_promoted=False,standard_suite=False,gameplay_ipc=None)
    save(root/'closed.json',result);print(json.dumps(result,indent=2),flush=True)
    return int(not result['passed'])


if __name__ == '__main__': raise SystemExit(main())
