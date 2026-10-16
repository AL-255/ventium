"""Account every retained cycle-counter tick without altering gate verdicts.

Retirement gaps are observations, not inferred cache misses or pipeline stalls.
Repeated backward-edge intervals expose warm behavior separately; the original
cold full-stream results remain authoritative and are never trimmed/regraded.
"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'diff'))
import tracefmt


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def account(rows):
    assert rows and rows[0]['cyc'] >= 1
    assert [r['n'] for r in rows] == list(range(len(rows)))
    assert all(r['pipe'] in ('U', 'V', '-') for r in rows)
    assert all(isinstance(r['cyc'], int) for r in rows)
    assert all(a['cyc'] <= b['cyc'] for a, b in zip(rows, rows[1:]))
    groups = Counter(r['cyc'] for r in rows)
    times = sorted(groups)
    gaps = Counter(b-a for a, b in zip(times, times[1:]))
    initial = times[0]-1
    idle = sum((gap-1)*count for gap, count in gaps.items())
    active = len(groups)
    assert initial+active+idle == times[-1]
    backward = {}
    for i in range(1, len(rows)):
        a, b = [tracefmt.parse_hex(rows[n]['pc']) for n in (i-1, i)]
        if b < a:
            backward.setdefault((a, b), []).append(i)
    intervals = []
    for edge, indices in sorted(backward.items(), key=lambda item: (-len(item[1]), item[0])):
        if len(indices) < 3:
            continue
        spans = Counter((rows[b]['cyc']-rows[a]['cyc'], b-a) for a, b in zip(indices, indices[1:]))
        intervals.append(dict(from_pc=hex(edge[0]), to_pc=hex(edge[1]), occurrences=len(indices),
            intervals=[dict(cycles=c, instructions=n, count=count, cpi=c/n)
                       for (c, n), count in sorted(spans.items())]))
    return dict(records=len(rows), total_cycles=times[-1], initial_no_retirement_cycles=initial,
        active_retirement_cycles=active, later_no_retirement_cycles=idle,
        accounting_sum=initial+active+idle, total_cpi=times[-1]/len(rows),
        pipe_counts=dict(Counter(r['pipe'] for r in rows)),
        retirements_per_active_cycle=dict(sorted(Counter(groups.values()).items())),
        inter_retirement_cycle_gaps=[dict(cycle_distance=g, count=n, empty_cycles=(g-1)*n)
                                    for g, n in sorted(gaps.items())],
        repeated_backward_edges=intervals)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    core, out = args.core.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    started, closed = [json.loads((core/n).read_text()) for n in ('verify-started.json', 'verify-closed.json')]
    assert closed['canonical_gate_native_exit'] == 2 and not closed['canonical_gate_passed']
    assert closed['pins_unchanged'] and not closed['masks_or_goldens_or_bands_changed']
    pins = dict(started['pins'])
    for p in (Path(__file__).resolve(), Path(tracefmt.__file__), core/'verify-started.json', core/'verify-closed.json'):
        pins[str(p)] = sha(p)
    results = sorted((core/'generic-work').glob('*.cycle.result'))
    assert len(results) == 20
    kernels = []
    for result in results:
        fields = result.read_text().strip().split('|')
        assert len(fields) == 9 and fields[0] == 'CYCLE'
        rtl, golden = [Path(p).resolve(strict=True) for p in fields[4:6]]
        a, b = [tracefmt.read_trace(str(p)) for p in (rtl, golden)]
        assert a.mode == b.mode == 'cycle' and len(a.records) == len(b.records)
        assert [(r['n'], tracefmt.parse_hex(r['pc'])) for r in a.records] == [
            (r['n'], tracefmt.parse_hex(r['pc'])) for r in b.records]
        actual, reference = account(a.records), account(b.records)
        kernels.append(dict(name=fields[1], class_name=fields[2], original_result=fields,
            rtl=actual, reference=reference, total_cycle_delta=actual['total_cycles']-reference['total_cycles']))
        for p in (result, rtl, golden):
            pins[str(p)] = sha(p)
    assert all(sha(p) == h for p, h in pins.items())
    data = dict(audit_complete=True, source_model_sha256=sha(core/'obj/tb_ventium'), pins=pins,
        kernels=kernels, cycle_mode=1, canonical_gate_passed=False, standard_suite=False,
        hardware_acceptance=False, gameplay_ipc=None, traces_or_verdicts_changed=False,
        caveat='Counts account for all positive cumulative counter ticks. Empty retirement cycles do not by themselves identify a cache miss, pipeline state, or causal stall. Repeated-edge intervals are diagnostic only; cold gate verdicts remain unchanged.')
    with out.open('x') as f:
        json.dump(data, f, indent=2)
    for k in kernels:
        d = k['rtl']
        print(k['name'], 'cycles', d['total_cycles'], '=', d['initial_no_retirement_cycles'],
              'initial +', d['active_retirement_cycles'], 'retiring +', d['later_no_retirement_cycles'],
              'later empty; original delta', k['total_cycle_delta'])


if __name__ == '__main__':
    main()
