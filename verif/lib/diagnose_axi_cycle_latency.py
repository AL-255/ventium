#!/usr/bin/env python3
"""Native-only latency diagnostic; never changes timing bands or qualifies RTL.

Replay saved CYCLE argv against the same prebuilt model at AXI_RLAT=0,1,7,
AXI_WLAT=7. Also collect --cycle-func traces to check complete architectural
state across those latencies. No compiler, QEMU, debugger or RTL mutation.
"""
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
import sys
import time

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO / 'verif'), str(REPO / 'verif/diff')]
import m5_metrics
import tracefmt

KERNELS = ('depadd', 'indepadd', 'faddchain', 'dmiss', 'imiss',
           'mul', 'imul2', 'rmimm', 'nearbr')
SCRATCH = Path('/home/yukidama/external/tmp')
REQUIRED = {'VEN_L1_AXI', 'VEN_L1D_PERF', 'VEN_SYS_FASTPATH',
            'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTLOAD_BOUNDED', 'VEN_SYS_FASTSTORE_FLAT'}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def decode_argv(path, tb):
    raw = Path(path).read_bytes()
    assert raw.endswith(b'\0'), 'incomplete argv receipt'
    argv = [part.decode() for part in raw.split(b'\0')[:-1]]
    assert Path(argv[0]).resolve(strict=True) == tb
    assert argv.count('--cycle') == 1 and argv.count('--l1-axi') == 1
    # Reject unexpected/debug/mode overrides rather than silently remove them.
    scalar = {'--image', '--load', '--entry', '--init-esp', '--out',
              '--max-insn', '--max-cycles'}
    switches = {'--cycle', '--l1-axi', '--x87'}
    seen = set()
    i = 1
    while i < len(argv):
        flag = argv[i]
        assert flag not in seen and flag in scalar | switches, flag
        seen.add(flag)
        i += 2 if flag in scalar else 1
        assert i <= len(argv)
    assert scalar <= seen
    return argv


def read_trace(path, mode, count):
    trace = tracefmt.read_trace(str(path))
    assert trace.mode == mode and len(trace.records) == count
    assert all(r['n'] == i for i, r in enumerate(trace.records))
    return trace.records


def native(case, output, tb, commands, base):
    name, latency, mode, cpu = case
    work = output / f'{name}-r{latency}-{mode}'
    work.mkdir()
    trace = work / 'rtl.vtrace'
    argv = list(commands[name])
    argv[argv.index('--out') + 1] = str(trace)
    if mode == 'func':
        argv[argv.index('--cycle')] = '--cycle-func'
    expected = int(argv[argv.index('--max-insn') + 1])
    command = ['taskset', '-c', str(cpu), *argv]
    env = dict(base, AXI_RLAT=str(latency), AXI_WLAT='7', TMPDIR=str(output))
    row = dict(kernel=name, read_latency=latency, write_latency=7,
               mode=mode, argv=command, cpu=cpu, passed=False,
               invocation=os.getenv('INVOCATION_ID'))
    save(work / 'started.json', row)
    started = time.monotonic()
    try:
        assert shutil.disk_usage(SCRATCH).free > 4 * 1024**3
        with (work / 'native.log').open('xb') as log:
            child = subprocess.Popen(command, env=env, cwd=work, stdout=log,
                                     stderr=subprocess.STDOUT, start_new_session=True)
            observed = None
            try:
                while child.poll() is None and time.monotonic() - started < 60:
                    if observed is None:
                        try:
                            proc = Path('/proc') / str(child.pid)
                            if (proc / 'exe').resolve(strict=True) == tb:
                                affinity = sorted(os.sched_getaffinity(child.pid))
                                assert affinity == [cpu], affinity
                                observed = dict(pid=child.pid, affinity=affinity,
                                                cgroup=(proc / 'cgroup').read_text(),
                                                stat=(proc / 'stat').read_text())
                        except FileNotFoundError:
                            pass
                    time.sleep(0.01 if observed is None else 0.05)
                if child.poll() is None:
                    raise TimeoutError('60-second native diagnostic cap')
                row['native_exit'] = child.returncode
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
        assert row['native_exit'] == 0
        assert observed, 'native identity/affinity not observed'
        row['observed'] = observed
        records = read_trace(trace, mode, expected)
        log = (work / 'native.log').read_text()
        counts = re.search(r'retires\s+(\d+)\s+\(U=(\d+)\s+pairedV=(\d+)\)', log)
        backend = re.search(r'\[L1DPERF\] fill cycles=(\d+) backing-wait=(\d+) backing-ack=(\d+)', log)
        pairs = re.search(r'^\s*(\d+)\s+PAIRED\s+\(U \+ V retired\)', log, re.M)
        assert counts and backend and pairs
        total, u, v = map(int, counts.groups())
        assert total == u + v == expected and v > 0 and int(pairs[1]) > 0
        fill, wait, acks = map(int, backend.groups())
        assert acks > 0
        row.update(records=total, u=u, v=v, fast_pairs=int(pairs[1]),
                   fill_cycles=fill, backing_wait=wait, backing_acks=acks)
        if mode == 'cycle':
            vpairs = [i for i, r in enumerate(records) if r.get('pipe') == 'V']
            assert len(vpairs) == v
            assert all(i > 0 and records[i]['paired']
                       and records[i-1]['pipe'] == 'U'
                       and records[i-1]['cyc'] == records[i]['cyc'] for i in vpairs)
            row.update(cycles=records[-1]['cyc'], cpi=records[-1]['cyc'] / total)
        row['passed'] = True
    except Exception as exc:
        row['error'] = repr(exc)
    row['seconds'] = time.monotonic() - started
    row['artifacts'] = {str(p): sha(p) for p in work.iterdir() if p.is_file()}
    save(work / 'closed.json', row)
    print(json.dumps({k: v for k, v in row.items()
                      if k not in ('argv', 'artifacts', 'observed')}), flush=True)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gate-work', type=Path, required=True)
    parser.add_argument('--tb', type=Path, required=True)
    parser.add_argument('--model-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    tb = args.tb.resolve(strict=True)
    work = args.gate_work.resolve(strict=True)
    output = args.output.resolve()
    scratch = SCRATCH.resolve(strict=True)
    assert output.is_relative_to(scratch) and not output.exists()
    assert shutil.disk_usage(scratch).free > 4 * 1024**3
    assert sha(tb) == args.model_sha256
    stamp = tb.parent / 'Vventium_top__verFiles.dat'
    command_lines = [s for s in stamp.read_text().splitlines() if s.startswith('C ')]
    assert len(command_lines) == 1
    defines = sorted(set(re.findall(r'\+define\+([A-Z][A-Z0-9_]*)', command_lines[0])))
    assert REQUIRED <= set(defines)
    assert not {'VTM_NO_DPI', 'VEN_KV260_SOC', 'SYNTHESIS'} & set(defines)
    commands, goldens, prior, inputs = {}, {}, {}, [tb, stamp, Path(__file__),
        REPO/'verif/m4_metrics.py', REPO/'verif/m5_metrics.py', REPO/'verif/diff/tracefmt.py']
    for short in KERNELS:
        name = 'mb_' + short
        argvfile = work / f'{name}.cycle_rtl.argv'
        argv = decode_argv(argvfile, tb)
        commands[name] = argv
        result = work / f'{name}.cycle.result'
        fields = result.read_text().strip().split('|')
        assert fields[:2] == ['CYCLE', name] and fields[3] == '1'
        prior[name], goldens[name] = Path(fields[4]), Path(fields[5])
        assert prior[name] == Path(argv[argv.index('--out') + 1])
        inputs.extend([argvfile, result, prior[name], goldens[name],
                       Path(argv[argv.index('--image') + 1])])
    pins = {str(p.resolve()): sha(p) for p in inputs}
    output.mkdir()
    save(output/'started.json', dict(pins=pins, defines=defines, model=sha(tb),
        invocation=os.getenv('INVOCATION_ID'), cycle_mode=1, native_timeout=60,
        workers=2, cpu_affinity=[12, 13], gameplay_ipc=None, acceptance=False))
    base = {k: v for k, v in os.environ.items()
            if not k.startswith(('VEN_', 'VTM_', 'TB_', 'AXI_', 'QEMU_'))}
    cases = [(name, latency, mode, 12 + i % 2)
             for i, (name, latency, mode) in enumerate(
                 (n, l, m) for n in commands for l in (0, 1, 7) for m in ('cycle', 'func'))]
    with ThreadPoolExecutor(max_workers=2) as pool:
        rows = list(pool.map(lambda c: native(c, output, tb, commands, base), cases))
    checks = {}
    for name in commands:
        count = int(commands[name][commands[name].index('--max-insn') + 1])
        cycles = [read_trace(output/f'{name}-r{l}-cycle/rtl.vtrace', 'cycle', count) for l in (0, 1, 7)]
        funcs = [read_trace(output/f'{name}-r{l}-func/rtl.vtrace', 'func', count) for l in (0, 1, 7)]
        old = read_trace(prior[name], 'cycle', count)
        pcs = [[r['pc'] for r in trace] for trace in cycles + funcs]
        checks[name] = dict(cycle_r7_identical=cycles[2] == old,
            full_functional_records_identical=funcs[0] == funcs[1] == funcs[2],
            pc_sequences_identical=all(p == pcs[0] for p in pcs),
            diagnostic_bands={str(l): m5_metrics.compute(name,
                str(output/f'{name}-r{l}-cycle/rtl.vtrace'), str(goldens[name])) for l in (0, 1, 7)})
    stable = all(sha(p) == digest for p, digest in pins.items())
    passed = stable and all(row['passed'] for row in rows) and all(
        c['cycle_r7_identical'] and c['full_functional_records_identical']
        and c['pc_sequences_identical'] for c in checks.values())
    save(output/'closed.json', dict(passed=passed, inputs_unchanged=stable,
        rows=rows, checks=checks, cycle_band_acceptance=False, standard_suite=False,
        hardware_acceptance=False, gameplay_ipc=None,
        artifacts={str(p): sha(p) for p in output.rglob('*') if p.is_file()}))
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
