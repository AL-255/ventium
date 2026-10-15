"""Real worker/QEMU/RTL regressions for the composed cache-key repair.

Reuse all fourteen original stale-mode witnesses, then check both cycle ESP
lookups. No RTL, oracle, architectural comparator or timing band changes.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import time

import prepare_worker_cache_identity as recipe
import test_preexit_cache_native as base


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    root = parser.parse_args().out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.sched_getaffinity(0) == set(range(13, 17)) and os.environ['INVOCATION_ID']
    assert shutil.disk_usage(scratch).free > 4 * 1024**3 + 64 * 1024**2
    old = base.REPO / 'verif/lib/verify_worker.sh'
    text = recipe.transform(old.read_text())
    assert recipe.original(text) == old.read_text()
    qemu = scratch / 'ventium-qemu-frndint.wRXifJwr/build-r1/build/qemu-i386'
    model = scratch / 'ventium-data-size.v2HaTO2X/core-r1/obj/tb_ventium'
    assert base.sha(qemu) == 'da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d'
    assert base.sha(model) == 'fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041'
    ref = base.REPO / 'ventium-refs/07-p5-emulation-harness'
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('VEN_', 'VTM_', 'TB_', 'AXI_', 'QEMU_', 'VERIFY_'))}
    env.update(QEMU=str(qemu), ISA_VERIFY=str(ref / 'tools/isa_verify.py'),
        GEN_TRACE=str(base.REPO / 'verif/qemu-trace/gen_trace.py'),
        COMPARE=str(base.REPO / 'verif/diff/compare.py'),
        ELF2FLAT=str(base.REPO / 'verif/tests/elf2flat.py'),
        P5TRACE=str(base.REPO / 'build/p5trace.so'), TB_BIN=str(model),
        M5_METRICS=str(base.REPO / 'verif/m5_metrics.py'), PYTHON='/usr/bin/python3', CC='/usr/bin/gcc',
        CFLAGS_BASE='-m32 -march=pentium -nostdlib -static -Wl,--build-id=none',
        M5_TOL_PCT='10', TB_EXTRA_FLAGS='--cycle-func --l1-axi', AXI_RLAT='7', AXI_WLAT='7',
        TMPDIR=str(root))
    root.mkdir()
    fixed = root / 'verify_worker.sh'
    with fixed.open('x') as stream:
        stream.write(text)
    pins = {str(p): base.sha(p) for p in (old, fixed, Path(__file__), Path(base.__file__),
        Path(recipe.__file__), Path(recipe.preexit.__file__), Path(base.tracefmt.__file__),
        base.REPO / 'verif/tests/smoke/smoke.s', model.parent / 'Vventium_top__verFiles.dat',
        *(Path(env[k]) for k in ('QEMU', 'ISA_VERIFY', 'GEN_TRACE', 'COMPARE', 'ELF2FLAT',
                                'P5TRACE', 'TB_BIN', 'M5_METRICS')))}
    base.save(root / 'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID']))
    sequences = []
    rows, errors = [], []
    try:
        specs = [('old-off-first', 13, False, [None, '1']),
                 ('old-on-first', 14, False, ['1', None]),
                 ('fixed-off-first', 15, True, [None, '1', '0', 'yes', '', '1']),
                 ('fixed-on-first', 16, True, ['1', None, '1', '01'])]
        with ThreadPoolExecutor(max_workers=4) as pool:
            sequences = list(pool.map(lambda spec: base.run_sequence(spec, root, env, old, fixed), specs))
        for mode in ('0', '1'):
            work = root / ('cycle-mode' + mode)
            work.mkdir()
            cache = root / 'fixed-off-first/cache'
            golden = list(cache.glob(f'*.func.preexit{mode}.x870.max22.vtrace'))
            assert len(golden) == 1
            gold = base.tracefmt.read_trace(str(golden[0]))
            scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
            qemu = scratch / 'ventium-qemu-frndint.wRXifJwr/build-r1/build/qemu-i386'
            model = scratch / 'ventium-data-size.v2HaTO2X/core-r1/obj/tb_ventium'
            ref = base.REPO / 'ventium-refs/07-p5-emulation-harness'
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('VEN_', 'VTM_', 'TB_', 'AXI_', 'QEMU_', 'VERIFY_'))}
            env.update(QEMU=str(qemu), ISA_VERIFY=str(ref / 'tools/isa_verify.py'),
                GEN_TRACE=str(base.REPO / 'verif/qemu-trace/gen_trace.py'),
                COMPARE=str(base.REPO / 'verif/diff/compare.py'),
                ELF2FLAT=str(base.REPO / 'verif/tests/elf2flat.py'),
                P5TRACE=str(base.REPO / 'build/p5trace.so'), TB_BIN=str(model),
                M5_METRICS=str(base.REPO / 'verif/m5_metrics.py'), PYTHON='/usr/bin/python3', CC='/usr/bin/gcc',
                CFLAGS_BASE='-m32 -march=pentium -nostdlib -static -Wl,--build-id=none',
                M5_TOL_PCT='10', TB_CYCLE_EXTRA_FLAGS='--l1-axi', AXI_RLAT='7', AXI_WLAT='7',
                TMPDIR=str(root), WORKDIR=str(work), CACHE_DIR=str(cache), PORTBASE='42500',
                VTM_QEMU_GDB_PREEXIT=mode, KCLASS='INT')
            command = ['taskset', '-c', '13', 'bash', '-x', str(root / 'verify_worker.sh'),
                       'cycle', 'smoke', str(base.REPO / 'verif/tests/smoke/smoke.s'),
                       '0x08048000', '0x08048000', '22', '0', '0', '-']
            before = time.monotonic()
            observed = False
            with (work / 'worker.log').open('x') as log:
                child = subprocess.Popen(command, env=env, cwd=base.REPO, stdout=log,
                    stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    while child.poll() is None:
                        assert time.monotonic() - before < 60
                        queue = [child.pid]
                        while queue:
                            pid = queue.pop()
                            try:
                                proc = Path('/proc') / str(pid)
                                queue.extend(map(int, (proc / 'task' / str(pid) / 'children').read_text().split()))
                                if (proc / 'exe').resolve() == model:
                                    assert os.sched_getaffinity(pid) == {13}
                                    observed = True
                            except (FileNotFoundError, ProcessLookupError):
                                pass
                        time.sleep(.001)
                    code = child.wait()
                finally:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGTERM)
                        try:
                            child.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.wait()
            assert code == 0 and observed and not (Path('/proc') / str(child.pid)).exists()
            log = (work / 'worker.log').read_text()
            assert re.findall(r'^\+ FUNC_GOLD=(.+)$', log, re.M) == [str(golden[0])]
            argv = (work / 'smoke.cycle_rtl.argv').read_bytes().split(b'\0')
            assert argv.pop() == b''
            argv = [s.decode() for s in argv]
            assert argv[argv.index('--init-esp') + 1] == gold.records[0]['esp']
            assert '--cycle' in argv and '--l1-axi' in argv
            result = (work / 'smoke.cycle.result').read_text().strip().split('|')
            assert result[3] == '1' and 'CONTROL-FLOW DIVERGENCE' not in '|'.join(result)
            assert result[-1] == mode, 'observer mode must not change cycle golden identity'
            trace = base.tracefmt.read_trace(str(work / 'smoke.cycle_rtl.vtrace'))
            assert len(trace.records) == 22 and sum(r.get('pipe') == 'V' for r in trace.records) == 8
            rows.append(dict(mode=mode, argv=argv, command=command, functional_golden=str(golden[0]),
                functional_sha256=base.sha(golden[0]), native_exit=code, actual_wait=True,
                child_affinity_observed=[13], child_reaped=True, records=22, v_retirements=8,
                cycle_cache_hit=int(result[-1]), result=result, seconds=time.monotonic() - before))
    except Exception as exc:
        import traceback
        errors.append(dict(error=repr(exc), traceback=traceback.format_exc()))
    stable = all(base.sha(p) == h for p, h in pins.items())
    cg = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().split('::', 1)[1].strip().lstrip('/')
    events = dict(s.split() for s in (cg / 'memory.events').read_text().splitlines())
    result = dict(passed=not errors and len(rows) == 2 and len(sequences) == 4 and stable
                         and all(events[k] == '0' for k in ('oom', 'oom_kill', 'oom_group_kill')),
        pins=pins, pins_unchanged=stable, sequences=sequences, memory_events=events,
        rows=rows, errors=errors, original_native_cases=14, additional_native_cases=2,
        canonical_worker_changed=False, oracle_promoted=False, standard_suite=False, gameplay_ipc=None)
    base.save(root / 'composed-closed.json', result)
    print(json.dumps({k: v for k, v in result.items() if k != 'pins'}, indent=2), flush=True)
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
