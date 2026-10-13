"""Replay both cache models on identical retained inputs; never mask ESP.

Separate private-QEMU runs inherit different loader stacks from their launch
environment. Compare complete traces from the same binary bytes and initial
ESP, including reproduction of the candidate's original functional trace.
"""
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

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'verif/diff'))
import tracefmt


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path): return json.loads(path.read_text())


def save(path, value):
    with path.open('x') as stream: json.dump(value, stream, indent=2)


def main():
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.sched_getaffinity(0) == set(range(13, 17)) and os.environ['INVOCATION_ID']
    assert shutil.disk_usage(scratch).free > 4 * 1024**3 + 100 * 1024**2
    evidence = scratch / 'ventium-data-size.v2HaTO2X'
    root = evidence / 'window-current-same-input-r1'
    assert not root.exists()
    func = evidence / 'window-current-func-r1'
    started, closed = load(func / 'started.json'), load(func / 'closed.json')
    assert closed['passed'] and closed['pins_unchanged'] and len(closed['rows']) == 108
    models = {label: evidence / name / 'obj/tb_ventium' for label, name in (
        ('parent', 'env-write-core-r1'), ('candidate', 'window-current-core-r1'))}
    assert sha(models['parent']) == '360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779'
    assert sha(models['candidate']) == started['model'] == '737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7'
    pins = dict(started['pins'])
    golden_by_name = {}
    for path in (func / 'private-enabled-cache').glob('*.vtrace'):
        trace = tracefmt.read_trace(str(path))
        name = re.search(r'elf=(\w+)\.func\.elf ', trace.hdr['note'])[1]
        assert name not in golden_by_name
        golden_by_name[name] = path
    assert len(golden_by_name) == 108
    cases = []
    for job in started['jobs']:
        name = job[1]
        image = func / 'work' / (name + '.func.flat')
        original = func / 'work' / (name + '.func_rtl.vtrace')
        golden = golden_by_name[name]
        records = tracefmt.read_trace(str(golden)).records
        esp = records[0]['esp']
        assert 0 <= int(esp, 0) < 2**32
        cases.append(dict(name=name, image=str(image), original=str(original),
            esp=esp, load=job[3], entry=job[4], maxinsn=job[5], x87=bool(int(job[6]))))
        for path in (image, original, golden): pins[str(path)] = sha(path)
    for path in (*models.values(), Path(__file__), Path(tracefmt.__file__), func / 'started.json', func / 'closed.json'):
        pins[str(path)] = sha(path)
    assert all(sha(p) == h for p, h in pins.items())
    root.mkdir()
    save(root / 'started.json', dict(pins=pins, cases=cases, invocation=os.environ['INVOCATION_ID'],
        models={k: str(v) for k, v in models.items()}, workers=4))
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VEN_', 'VTM_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(AXI_RLAT='7', AXI_WLAT='7', TMPDIR=str(root), PYTHONDONTWRITEBYTECODE='1')

    def run(index_case):
        index, case = index_case
        cpu = 13 + index % 4
        folder = root / case['name']; folder.mkdir()
        rows, traces, counts = [], {}, {}
        for label, model in models.items():
            path = folder / (label + '.vtrace')
            command = ['taskset', '-c', str(cpu), str(model), '--image', case['image'],
                '--load', case['load'], '--entry', case['entry'], '--init-esp', case['esp'],
                '--out', str(path), '--max-insn', case['maxinsn'],
                *(['--x87'] if case['x87'] else []), '--cycle-func', '--l1-axi']
            began = time.monotonic(); observed = False; error = None
            with (folder / (label + '.log')).open('x') as log:
                child = subprocess.Popen(command, cwd=REPO, env=env, stdout=log,
                    stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    while child.poll() is None:
                        if time.monotonic() - began > 60: raise subprocess.TimeoutExpired(command, 60)
                        try:
                            if Path('/proc', str(child.pid), 'exe').resolve(strict=True) == model:
                                assert os.sched_getaffinity(child.pid) == {cpu}
                                observed = True
                        except (FileNotFoundError, ProcessLookupError): pass
                        time.sleep(.001)
                    code = child.wait()
                except BaseException as exc:
                    error = repr(exc)
                    os.killpg(child.pid, signal.SIGTERM)
                    try: code = child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL); code = child.wait()
            rows.append(dict(label=label, command=command, pid=child.pid, native_exit=code,
                actual_wait=True, affinity_verified=observed, error=error, seconds=time.monotonic()-began))
            save(folder / (label + '-closed.json'), rows[-1])
            assert code == 0 and error is None and observed, rows[-1]
            text = (folder / (label + '.log')).read_text()
            assert '--l1-axi selected' in text and not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED', text)
            counts[label] = dict(clocks=int(re.search(r'^  clocks\s+(\d+)', text, re.M)[1]),
                                paired_v=int(re.search(r'pairedV=(\d+)', text)[1]))
            traces[label] = tracefmt.read_trace(str(path)).records
        assert traces['parent'] == traces['candidate'] == tracefmt.read_trace(case['original']).records
        assert counts['parent'] == counts['candidate']
        row = dict(name=case['name'], passed=True, records=len(traces['candidate']),
                   counts=counts, native=rows)
        save(folder / 'closed.json', row)
        return row

    began = time.monotonic(); rows = []; errors = []
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [(case['name'], pool.submit(run, (index, case))) for index, case in enumerate(cases)]
        for name, future in futures:
            try: rows.append(future.result())
            except Exception as exc: errors.append(dict(name=name, error=repr(exc)))
    stable = all(sha(p) == h for p, h in pins.items())
    cg = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().split('::', 1)[1].strip().lstrip('/')
    events = dict(line.split() for line in (cg / 'memory.events').read_text().splitlines())
    passed = stable and len(rows) == 108 and not errors and all(events[k] == '0' for k in ('oom', 'oom_kill', 'oom_group_kill'))
    result = dict(passed=passed, rows=rows, errors=errors, pins_unchanged=stable,
        seconds=time.monotonic()-began, memory_events=events, records=sum(r['records'] for r in rows),
        canonical_gate_passed=False, standard_suite=False, gameplay_ipc=None)
    save(root / 'closed.json', result)
    print(json.dumps({k: v for k, v in result.items() if k != 'rows'}), flush=True)
    return int(not passed)


if __name__ == '__main__': raise SystemExit(main())
