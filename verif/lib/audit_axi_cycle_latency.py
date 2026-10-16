#!/usr/bin/env python3
"""Recompute a closed native latency sweep from hashed logs and full traces."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

sys.path[:0] = [str(Path(__file__).resolve().parents[1]),
               str(Path(__file__).resolve().parents[1] / 'diff')]
import m5_metrics
import tracefmt


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def audit(root):
    started = json.loads((root/'started.json').read_text())
    closed = json.loads((root/'closed.json').read_text())
    pins = dict(started['pins'], **closed['artifacts'])
    assert all(sha(p) == h for p, h in pins.items()), 'input/artifact drift'
    assert closed['inputs_unchanged'] and closed['passed']
    assert not closed['cycle_band_acceptance'] and not closed['standard_suite']
    assert not closed['hardware_acceptance'] and closed['gameplay_ipc'] is None
    assert started['cycle_mode'] == 1 and started['workers'] == 2
    rows = closed['rows']
    index = {(r['kernel'], r['read_latency'], r['mode']): r for r in rows}
    names = sorted(closed['checks'])
    assert len(rows) == len(index) == len(names) * 6 == 54
    assert set(index) == {(n, l, m) for n in names for l in (0, 1, 7) for m in ('cycle', 'func')}
    traces, results = {}, {}
    for key, row in index.items():
        name, latency, mode = key
        work = root/f'{name}-r{latency}-{mode}'
        trace = tracefmt.read_trace(str(work/'rtl.vtrace'))
        assert trace.mode == mode
        assert all(r['n'] == i for i, r in enumerate(trace.records))
        assert row['passed'] and row['native_exit'] == 0
        assert row['invocation'] == started['invocation']
        assert row['observed']['affinity'] == [12 if mode == 'cycle' else 13]
        assert 'ventium-cycle-axi-latency-oct16-r1.service' in row['observed']['cgroup']
        assert row['write_latency'] == 7
        assert row['argv'][:3] == ['taskset', '-c', str(row['cpu'])]
        assert row['argv'].count('--l1-axi') == 1
        assert row['argv'].count('--cycle' if mode == 'cycle' else '--cycle-func') == 1
        assert not {'--dbg-step', '--dbg-bp', '--no-trace'} & set(row['argv'])
        assert sha(row['argv'][3]) == started['model']
        assert all(sha(p) == h for p, h in row['artifacts'].items())
        log = (work/'native.log').read_text()
        counts = tuple(map(int, re.search(r'retires\s+(\d+)\s+\(U=(\d+)\s+pairedV=(\d+)\)', log).groups()))
        assert counts == (row['records'], row['u'], row['v'])
        assert row['u'] + row['v'] == len(trace.records) and row['v'] > 0
        assert row['fast_pairs'] == int(re.search(r'^\s*(\d+)\s+PAIRED\s+\(U \+ V retired\)', log, re.M)[1]) > 0
        backend = tuple(map(int, re.search(r'\[L1DPERF\] fill cycles=(\d+) backing-wait=(\d+) backing-ack=(\d+)', log).groups()))
        assert backend == (row['fill_cycles'], row['backing_wait'], row['backing_acks'])
        assert row['backing_acks'] > 0
        if mode == 'cycle':
            assert trace.records[-1]['cyc'] == row['cycles']
            assert row['cpi'] == row['cycles']/len(trace.records)
            vpairs = [i for i, r in enumerate(trace.records) if r.get('pipe') == 'V']
            assert len(vpairs) == row['v']
            assert all(i > 0 and trace.records[i]['paired'] and trace.records[i-1]['pipe'] == 'U'
                       and trace.records[i]['cyc'] == trace.records[i-1]['cyc'] for i in vpairs)
        traces[key] = trace.records
    for name in names:
        prior_path = next(Path(p) for p in started['pins'] if p.endswith(f'/{name}.cycle.result'))
        fields = prior_path.read_text().strip().split('|')
        assert traces[name, 7, 'cycle'] == tracefmt.read_trace(fields[4]).records
        assert traces[name, 0, 'func'] == traces[name, 1, 'func'] == traces[name, 7, 'func']
        pcs = [[r['pc'] for r in traces[name, l, m]] for l in (0, 1, 7) for m in ('cycle', 'func')]
        assert all(p == pcs[0] for p in pcs)
        bands = {str(l): list(m5_metrics.compute(name, str(root/f'{name}-r{l}-cycle/rtl.vtrace'), fields[5])) for l in (0, 1, 7)}
        assert bands == closed['checks'][name]['diagnostic_bands']
        cycles = [index[name, l, 'cycle']['cycles'] for l in (0, 1, 7)]
        assert cycles[0] < cycles[1] < cycles[2]
        acks = index[name, 7, 'cycle']['backing_acks']
        results[name] = dict(cycles_r0_r1_r7=cycles,
            saved_cycles_r7_to_r0=cycles[2]-cycles[0], seven_times_backing_acks=7*acks,
            diagnostic_band_verdicts=[bands[str(l)][0] for l in (0, 1, 7)])
    return dict(passed=True, input_and_artifact_pins=len(pins), native_runs=len(rows),
        per_latency_functional_records=sum(index[n, 0, 'func']['records'] for n in names),
        results=results, closed_sha256=sha(root/'closed.json'),
        auditor_sha256=sha(__file__), cycle_band_acceptance=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    args = parser.parse_args()
    result = audit(args.root.resolve(strict=True))
    with (args.root/'audit.json').open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps(result, indent=2))
