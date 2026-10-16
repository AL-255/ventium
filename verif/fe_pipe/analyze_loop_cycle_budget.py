"""Partition complete existing cycle traces; never change a gate or trim a trace.

Loop entries are explicit ELF addresses supplied by the caller. Intervals between
visits are observations, not an assumption that caches or prediction are warm.
All clocks, including startup, first traversal and final traversal/exit, remain
in the accounting. This is diagnostic evidence, not performance acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'diff'))
import tracefmt


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def validate(records):
    require(bool(records), 'empty trace')
    previous = 0
    for index, row in enumerate(records):
        require(row['n'] == index, 'noncontiguous retirement sequence')
        require(type(row['cyc']) is int and row['cyc'] >= previous,
                'negative/nonmonotonic/noninteger clock')
        require(row['pipe'] in ('U', 'V'), 'unknown retirement pipe')
        require(type(row['paired']) is bool, 'missing boolean pair evidence')
        previous = row['cyc']
        tracefmt.parse_hex(row['pc'])


def partition(records, entry):
    validate(records)
    visits = [i for i, row in enumerate(records)
              if tracefmt.parse_hex(row['pc']) == entry]
    require(len(visits) >= 3, 'need at least three visits to explicit loop entry')
    edges = [records[i]['cyc'] for i in visits]
    intervals = [b-a for a, b in zip(edges, edges[1:])]
    phases = dict(startup=edges[0], first_traversal=intervals[0],
                  repeated_traversals=sum(intervals[1:]),
                  final_traversal_and_exit=records[-1]['cyc']-edges[-1])
    require(sum(phases.values()) == records[-1]['cyc'], 'lost/double-counted clocks')
    return dict(total_clocks=records[-1]['cyc'], records=len(records),
                u_retirements=sum(r['pipe'] == 'U' for r in records),
                v_retirements=sum(r['pipe'] == 'V' for r in records),
                loop_entry=f'0x{entry:08x}', visit_indices=visits,
                interval_clocks=intervals, phases=phases)


def compare(golden, rtl, entry):
    validate(golden)
    validate(rtl)
    require(len(golden) == len(rtl), 'complete streams differ in length')
    require(all(tracefmt.parse_hex(a['pc']) == tracefmt.parse_hex(b['pc'])
                for a, b in zip(golden, rtl)), 'complete PC streams differ')
    a, b = partition(golden, entry), partition(rtl, entry)
    require(a['visit_indices'] == b['visit_indices'], 'loop boundaries differ')
    delta = {k: b['phases'][k]-a['phases'][k] for k in a['phases']}
    total = b['total_clocks']-a['total_clocks']
    require(sum(delta.values()) == total, 'clock delta not conserved')
    return dict(golden=a, rtl=b, phase_deltas=delta, total_delta=total,
                interval_deltas=[y-x for x, y in zip(a['interval_clocks'], b['interval_clocks'])])


def fsm_budget(log, clocks):
    rows = re.findall(r'^    state\s+(\d+)\s+(\d+)\s+[\d.]+%$', log, re.M)
    require(rows and len({n for n, _ in rows}) == len(rows), 'missing/duplicate FSM budget')
    counts = {n: int(value) for n, value in rows}
    require(sum(counts.values()) == clocks, 'FSM budget does not cover full trace clocks')
    return counts


def analyze(work, entries):
    pins = {}
    results = {}
    def pin(path):
        path = path.resolve(strict=True)
        pins[str(path)] = sha(path)
        return path
    for name, entry in entries.items():
        path = pin(work/(name+'.cycle.result'))
        fields = path.read_text().strip().split('|')
        require(len(fields) == 9 and fields[:2] == ['CYCLE', name] and fields[3] == '1',
                'missing/failed native cycle production')
        rtl, golden = (pin(Path(p)) for p in fields[4:6])
        require(rtl == (work/(name+'.cycle_rtl.vtrace')).resolve(), 'wrong RTL trace')
        traces = [tracefmt.read_trace(str(p)) for p in (golden, rtl)]
        require(all(t.mode == 'cycle' for t in traces), 'not cycle observations')
        row = compare(traces[0].records, traces[1].records, entry)
        log = pin(work/(name+'.cycle_rtl.log'))
        row['fsm_clocks'] = fsm_budget(log.read_text(), row['rtl']['total_clocks'])
        row['canonical_comparator'] = fields[6]
        row['canonical_total_comparison'] = fields[7]
        results[name] = row
    pin(Path(__file__))
    pin(Path(tracefmt.__file__))
    return dict(diagnostic_only=True, gate_changed=False, trace_records_removed=0,
                all_clocks_accounted=True, kernels=results, pins=pins)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--work', type=Path, required=True)
    ap.add_argument('--kernel', action='append', required=True, metavar='NAME=ENTRY')
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    pairs = [s.split('=') for s in args.kernel]
    require(all(len(p) == 2 for p in pairs), 'kernel must be NAME=ENTRY')
    require(len({p[0] for p in pairs}) == len(pairs), 'duplicate kernel')
    require(all(re.fullmatch(r'mb_[a-z0-9_]+', p[0]) for p in pairs), 'invalid kernel name')
    result = analyze(args.work.resolve(strict=True), {n: int(e, 0) for n, e in pairs})
    require(all(sha(p) == h for p, h in result['pins'].items()), 'input drift during analysis')
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2)
    for name, row in result['kernels'].items():
        print(name, row['total_delta'], row['phase_deltas'])


if __name__ == '__main__':
    main()
