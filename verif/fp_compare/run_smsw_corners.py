"""Replay retained cold SMSW privilege/retry fixtures on the timing candidate.

No compilation, new golden, guest edits, trace filtering or extra masks. This
qualifies 60 privilege cases and 25 paging/retry cases at each latency 0/7/31;
it neither includes nor relabels the known QEMU LOCK/segment disagreements.
"""
import argparse
import concurrent.futures
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
import traceback

REPO = Path(__file__).resolve().parents[2]
SCRATCH = Path('/home/yukidama/external/tmp').resolve(strict=True)
MODEL = '5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8'
CORPORA = (
    ('smsw-privilege-r2', 60, 7, '718ff31e6f314bed2c5969a71a6b3eeac096a056e0d9edfe62e7ef49d3966da3'),
    ('smsw-retry-l0-r1', 25, 0, 'b7cef0600ca520fa43eb420b2781ab194be02a52fe281c1b4074b41bbafcad30'),
    ('smsw-retry-l7-r1', 25, 7, 'cb9ec88b626dcb87224d3880dded680058959fa3d40d8f71d0cbcabeeecffe23'),
    ('smsw-retry-l31-r1', 25, 31, '07b677ac6d035c5dd2b3984f75b831fce56f999160b6b30e5605a49b69e55fbd'),
)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def command(old, model, fixture, output):
    """Accept only the existing bounded cold invocation, changing two paths."""
    assert old[:2] == ['taskset', '-c'] and old[3:5] == ['timeout', '--kill-after=2s']
    assert old[5] in ('15s', '20s') and Path(old[6]).name == 'tb_ventium'
    expected = ['--system', '--cosim', '--cycle-func', '--l1-axi', '--image', str(fixture / 'probe.bin'),
        '--out', str(fixture / 'candidate.vtrace'), '--max-insn', '3000', '--max-cycles', '1000000',
        '--quiesce', '4096', '+ven_faultlog', '+ven_seglog']
    assert old[7:] == expected, 'retained command has unreviewed options'
    result = [str(model), *expected]
    result[result.index('--out') + 1] = str(output)
    return result


def admitted(sample, model, argv, cpu, group):
    # /proc/exe, cmdline and affinity are separate reads across taskset's exec.
    # Require a complete matching sample; a partial/transition sample proves
    # nothing and must never be promoted to an admission receipt.
    return (sample['exe'] == str(model) and sample['affinity'] == [cpu] and
            sample['argv'] == argv and sample['cgroup'] == group)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', required=True, type=Path)
    ap.add_argument('--unit', required=True)
    args = ap.parse_args()
    root = args.out.resolve()
    core = SCRATCH / 'ventium-data-size.v2HaTO2X/fp-compare-core-r1'
    model = core / 'obj/tb_ventium'
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == SCRATCH
    assert root.is_relative_to(SCRATCH) and root != SCRATCH and not root.exists()
    assert os.sched_getaffinity(0) == {12, 13}
    assert shutil.disk_usage(SCRATCH).free > 4 * 1024**3 + 128 * 1024**2
    unit = args.unit
    assert re.fullmatch(r'ventium-fp-compare-smswcorners-oct14-r[12]\.service', unit)
    invocation = subprocess.check_output(['systemctl', '--user', 'show', unit,
                                         '-p', 'InvocationID', '--value'], text=True).strip()
    assert invocation == os.environ['INVOCATION_ID']
    cg = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().split('::', 1)[1].strip().lstrip('/')
    assert cg.name == unit
    assert (cg / 'memory.max').read_text().strip() == str(1024**3)
    assert (cg / 'memory.swap.max').read_text().strip() == '0'
    before, built = load(core / 'build-started.json'), load(core / 'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(model) == built['binary_sha256'] == MODEL
    definitions = before['definitions']
    assert len(definitions) == len(set(definitions)) == 152
    assert {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT'} <= set(definitions)
    pins = dict(before['pins'])
    for path in (Path(__file__), core / 'build-started.json', core / 'build-closed.json', model,
                 REPO / 'verif/diff/compare.py', REPO / 'verif/diff/tracefmt.py'):
        pins[str(path)] = sha(path)
    jobs = []
    for name, count, latency, digest in CORPORA:
        source = SCRATCH / 'ventium-load-read-ack.GyWDDtiI' / name
        assert sha(source / 'closed.json') == digest
        closed = load(source / 'closed.json')
        assert closed['passed'] and closed['pins_unchanged'] and closed['errors'] == []
        assert len(closed['rows']) == count and all(row['passed'] for row in closed['rows'])
        pins[str(source / 'closed.json')] = digest
        pins.update(load(source / 'started.json')['pins'])
        for row in closed['rows']:
            assert re.fullmatch(r'[a-z0-9-]+', row['name'])
            pins.update(row['artifacts'])
            fixture = source / row['name']
            argv = load(fixture / 'candidate-command.json')['argv']
            jobs.append(dict(corpus=name, latency=latency, row=row, fixture=fixture, argv=argv))
    assert len(jobs) == 135 and all(sha(path) == expected for path, expected in pins.items())
    root.mkdir()
    save(root / 'started.json', dict(pins=pins, model=MODEL, invocation=invocation,
        unit=unit, affinity=[12, 13], definitions=definitions, cases=135,
        cold_reset=True, compiler_started=False, hardware_acceptance=False, standard_suite=False))
    sys.path.insert(0, str(REPO / 'verif/diff'))
    import tracefmt

    def run_case(index, job):
        row, fixture = job['row'], job['fixture']
        out = root / (job['corpus'] + '-' + row['name'])
        out.mkdir()
        assert shutil.disk_usage(root).free > 4 * 1024**3
        argv = command(job['argv'], model, fixture, out / 'candidate.vtrace')
        cpu = 12 + index % 2
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('VEN_', 'VENTIUM_', 'VTM_', 'TB_', 'AXI_', 'QEMU_'))}
        env.update(AXI_RLAT=str(job['latency']), AXI_WLAT=str(job['latency']), PYTHONDONTWRITEBYTECODE='1')
        save(out / 'command.json', dict(argv=argv, cpu=cpu, axi_latency=job['latency']))
        observed, admission_samples = None, []
        with (out / 'native.log').open('x') as log:
            child = subprocess.Popen(['taskset', '-c', str(cpu), *argv], env=env, cwd=out,
                                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            proc = Path('/proc') / str(child.pid)
            begin = time.monotonic()
            try:
                while child.poll() is None:
                    assert time.monotonic() - begin < 20, 'native timeout'
                    if observed is None:
                        assert time.monotonic() - begin < 3, 'no complete native admission within three seconds'
                        try:
                            sample = dict(pid=child.pid, exe=str((proc / 'exe').resolve(strict=True)),
                                affinity=sorted(os.sched_getaffinity(child.pid)),
                                argv=(proc / 'cmdline').read_bytes().rstrip(b'\0').decode().split('\0'),
                                cgroup=(proc / 'cgroup').read_text())
                            # Retain bounded transition evidence, without altering
                            # the actual native argv or accepting a wrong sample.
                            if not admission_samples or sample != admission_samples[-1]:
                                assert len(admission_samples) < 32, 'unstable native admission'
                                admission_samples.append(sample)
                            if admitted(sample, model, argv, cpu, Path('/proc/self/cgroup').read_text()):
                                observed = sample
                        except (FileNotFoundError, ProcessLookupError):
                            pass
                    for path in (out / 'native.log', out / 'candidate.vtrace'):
                        assert not path.exists() or path.stat().st_size <= 8 * 1024**2
                    time.sleep(.001)
                native = child.wait()
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                save(out / 'native-closed.json', dict(native_exit=child.returncode, observed=observed,
                    admission_samples=admission_samples,
                    actual_wait=True, process_absent=not proc.exists()))
        assert native == 133 and observed and not proc.exists()
        log = (out / 'native.log').read_text()
        assert 'isa-debug-exit' in log and not re.search(r'%Error|Assertion failed|CPU HUNG', log)
        trace = tracefmt.read_trace(str(out / 'candidate.vtrace'))
        assert trace.sys and trace.mode == 'func' and len(trace.records) == row['records']
        assert int(trace.records[-1]['eax'], 16) & 255 == 0x42
        compare = [sys.executable, '-B', str(REPO / 'verif/diff/compare.py'), '--mode', 'func',
                   str(fixture / 'golden.vtrace'), str(out / 'candidate.vtrace')]
        with (out / 'compare.log').open('x') as log_file:
            compared = subprocess.run(compare, stdout=log_file, stderr=subprocess.STDOUT, timeout=10)
        text = (out / 'compare.log').read_text()
        assert compared.returncode == 0 and 'RESULT: EQUIVALENT' in text and 'sys compared: True' in text
        value = dict(corpus=job['corpus'], case=row['name'], latency=job['latency'], passed=True,
                     native_exit=native, compare_exit=0, records=len(trace.records),
                     artifacts={str(path): sha(path) for path in out.iterdir() if path.is_file()})
        save(out / 'closed.json', value)
        return value

    begin = time.monotonic()
    results, errors = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = {pool.submit(run_case, index, job): job for index, job in enumerate(jobs)}
        for future in concurrent.futures.as_completed(futures):
            try:
                results.append(future.result())
            except Exception as error:
                job = futures[future]
                errors.append(dict(corpus=job['corpus'], case=job['row']['name'],
                                   error=repr(error), traceback=traceback.format_exc()))
    stable = all(sha(path) == expected for path, expected in pins.items())
    events = dict(line.split() for line in (cg / 'memory.events').read_text().splitlines())
    passed = len(results) == 135 and not errors and stable and events['oom'] == events['oom_kill'] == '0'
    value = dict(passed=passed, rows=results, errors=errors, pins_unchanged=stable, memory_events=events,
                 seconds=time.monotonic() - begin, records=sum(row['records'] for row in results),
                 standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    save(root / 'closed.json', value)
    print(json.dumps({k: v for k, v in value.items() if k != 'rows'}), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
