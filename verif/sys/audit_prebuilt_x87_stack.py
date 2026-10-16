#!/usr/bin/env python3
"""Audit retained prebuilt stack-fault probes, preserving controller failures.

Count fault deliveries, not every diagnostic mentioning a vector. Cross-check
the RTL delivery log, the testbench observer and the in-guest handler witness.
This does not rebuild fixtures, modify masks, or qualify the standard suite.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'diff'))
import tracefmt

CASES = {'px87stk': (14, 30), 'px87stk2': (6, 12), 'px87stk3': (10, 21)}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fault_deliveries(log, expected):
    delivered = [(int(vec), int(pc, 16), int(err, 16)) for vec, err, pc in
                 re.findall(r'^\[FAULT\] vec=(\d+) err=([0-9a-fA-F]{8}) pc=([0-9a-fA-F]{8})\b', log, re.M)]
    observed = [(int(vec), int(pc, 16), int(err, 16)) for vec, pc, err in
                re.findall(r'^tb: FLT vec=(\d+) fault_pc=([0-9a-fA-F]{8}) cs=[0-9a-fA-F]{4} err=([0-9a-fA-F]{8})\b', log, re.M)]
    summary = re.findall(r'^\[fault-deliveries\] actual=(\d+)$', log, re.M)
    assert summary == [str(expected)], 'missing/duplicate/wrong delivery count'
    assert len(delivered) == expected and delivered == observed, 'fault observer disagreement'
    assert all(vec == 16 and err == 0 for vec, pc, err in delivered), 'unexpected fault'
    return delivered


def witness(last, expected_faults, expected_cases):
    assert int(last['edi'], 16) == 0x42, 'guest check failed'
    assert int(last['ebx'], 16) == expected_faults, 'handler-entry count'
    assert int(last['ecx'], 16) == expected_cases, 'completed-case count'
    assert int(last['edx'], 16) == 0x600d00f4, 'missing final pass magic'


def audit(root):
    start = json.loads((root / 'started.json').read_text())
    closed = json.loads((root / 'closed.json').read_text())
    # This audit describes the retained grading failure, never overwrites it.
    assert closed['passed'] is False and closed['inputs_unchanged']
    unit = 'ventium-stack-sentinel-oct16-r1.service'
    owner = dict(line.split('=', 1) for line in subprocess.check_output(
        ['systemctl', '--user', 'show', unit, '-p', 'ActiveState', '-p', 'SubState',
         '-p', 'MainPID', '-p', 'InvocationID', '-p', 'ExecMainStatus'], text=True).splitlines())
    assert owner == dict(ActiveState='failed', SubState='failed', MainPID='0',
                         InvocationID=start['invocation'], ExecMainStatus='1')
    pins = dict(start['pins'])
    for row in closed['rows']:
        pins.update(row['artifacts'])
    assert all(sha(p) == digest for p, digest in pins.items()), 'source/artifact drift'
    traces, evidence = {}, []
    keys = {(r['model'], r['case'], r['latency']) for r in closed['rows']}
    assert len(keys) == len(closed['rows']) == 12
    assert keys == {(m, n, l) for m in ('parent', 'candidate') for n in CASES for l in (0, 7)}
    for row in closed['rows']:
        model, name, latency = row['model'], row['case'], row['latency']
        work = root / f'{model}-{name}-r{latency}'
        log = (work / 'native.log').read_text()
        trace = tracefmt.read_trace(str(work / 'rtl.vtrace'))
        assert row['native_exit'] == 0 and row['error'] == 'AssertionError()'
        assert row['observed']['affinity'] == [12 if latency == 0 else 13]
        assert unit in row['observed']['cgroup']
        assert '--cycle-func' in row['argv'] and '--l1-axi' in row['argv']
        assert not {'--dbg-step', '--dbg-bp', '--no-trace'} & set(row['argv'])
        assert sha(row['argv'][3]) == start['models'][model]
        assert trace.mode == 'func' and trace.x87 and trace.sys
        records = trace.records
        assert 1500 < len(records) < 4000 and all(r['n'] == i for i, r in enumerate(records))
        mf, cases = CASES[name]
        witness(records[-1], mf, cases)
        delivered = fault_deliveries(log, mf)
        assert row['vectors'] == [16] * (2 * mf), 'different original grading failure'
        counts = tuple(map(int, re.search(r'retires\s+(\d+)\s+\(U=(\d+)\s+pairedV=(\d+)\)', log).groups()))
        assert counts[0] == counts[1] + counts[2] == len(records) and counts[2] > 0
        fast_pairs = int(re.search(r'^\s*(\d+)\s+PAIRED\s+\(U \+ V retired\)', log, re.M)[1])
        assert fast_pairs > 0 and int(re.search(r'backing-ack=(\d+)', log)[1]) > 0
        traces[model, name, latency] = records
        evidence.append(dict(model=model, case=name, latency=latency,
            records=len(records), u=counts[1], v=counts[2], fast_pairs=fast_pairs,
            completed_cases=cases, fault_deliveries=delivered))
    for name in CASES:
        base = traces['parent', name, 0]
        assert all(traces[m, name, l] == base for m in ('parent', 'candidate') for l in (0, 7))
    for p in (root/'started.json', root/'closed.json', Path(__file__), Path(tracefmt.__file__)):
        pins[str(p.resolve())] = sha(p)
    return dict(native_selfchecks_passed=True, native_runs=12, rows=evidence, pins=pins,
        full_architectural_records_equal=True, original_controller_passed=False,
        original_failure='double-counted two fault observers; px87stk3 expects 21, not 20 cases',
        retained_owner=owner, images_rebuilt_from_sources=False,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    args = parser.parse_args()
    result = audit(args.root.resolve(strict=True))
    with (args.root/'independent-audit.json').open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps({k: v for k, v in result.items() if k not in ('pins', 'rows')}, indent=2))
