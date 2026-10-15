#!/usr/bin/env python3
"""Account for every saved cycle-gate retirement interval without changing it.

First/revisited PC is an observation, NOT a cache hit/miss classification.
Neither subtracting startup nor matching repeated PCs changes the gate verdict.
This reads existing traces through tracefmt; it never launches a simulator.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent/'diff'))
import tracefmt


def summarize(golden, rtl):
    if not golden or len(golden) != len(rtl):
        raise ValueError('empty or unequal complete instruction streams')
    buckets = {name: Counter() for name in ('first_pc', 'revisited_pc')}
    by_pc, seen = defaultdict(Counter), set()
    previous_a = previous_c = 0
    for index, (a, c) in enumerate(zip(golden, rtl)):
        if a['n'] != index or c['n'] != index or a['pc'] != c['pc']:
            raise ValueError('instruction identity/order mismatch')
        now_a, now_c = a['cyc'], c['cyc']
        if (type(now_a) is not int or type(now_c) is not int or
                now_a < previous_a or now_c < previous_c):
            raise ValueError('invalid or decreasing cycle counter')
        da, dc = now_a-previous_a, now_c-previous_c
        kind = 'revisited_pc' if a['pc'] in seen else 'first_pc'
        seen.add(a['pc'])
        buckets[kind].update(records=1, golden_clocks=da, rtl_clocks=dc,
                             excess_clocks=dc-da, v_records=int(c.get('pipe') == 'V'))
        by_pc[(a['pc'], kind)][(da, dc)] += 1
        previous_a, previous_c = now_a, now_c
    assert sum(b['records'] for b in buckets.values()) == len(rtl)
    assert sum(b['golden_clocks'] for b in buckets.values()) == previous_a
    assert sum(b['rtl_clocks'] for b in buckets.values()) == previous_c
    assert sum(b['excess_clocks'] for b in buckets.values()) == previous_c-previous_a
    return dict(records=len(rtl), golden_clocks=previous_a, rtl_clocks=previous_c,
        excess_clocks=previous_c-previous_a, buckets=buckets,
        pc_intervals=[dict(pc=pc, kind=kind, golden_delta=da, rtl_delta=dc, count=count)
                      for (pc, kind), counts in sorted(by_pc.items())
                      for (da, dc), count in sorted(counts.items())])


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def analyze(root):
    start_file, end_file = root/'verify-started.json', root/'verify-closed.json'
    start, end = json.loads(start_file.read_text()), json.loads(end_file.read_text())
    env = start['environment']
    work = Path(env['VERIFY_WORKDIR']).resolve(strict=True)
    model = Path(env['TB_BIN']).resolve(strict=True)
    assert work == root/'generic-work' and end['pins_unchanged']
    assert not end['masks_or_goldens_or_bands_changed']
    assert sha(model) == start['pins'][str(model)]
    paths = [start_file, end_file, model, Path(__file__).resolve(), Path(tracefmt.__file__).resolve()]
    rows = []
    files = sorted(work.glob('*.cycle.result'))
    assert len(files) == 20, 'expected the complete canonical 20-kernel cycle corpus'
    for result in files:
        fields = result.read_text().strip().split('|')
        assert len(fields) == 9 and fields[0] == 'CYCLE' and fields[3] == '1'
        name, rtl_path, golden_path = fields[1], Path(fields[4]), Path(fields[5])
        argv_path, log_path = work/(name+'.cycle_rtl.argv'), work/(name+'.cycle_rtl.log')
        argv = argv_path.read_bytes().decode().rstrip('\0').split('\0')
        assert Path(argv[0]).resolve(strict=True) == model
        assert '--cycle' in argv and '--l1-axi' in argv
        assert not {'--cycle-func','--dbg-step','--dbg-bp','--no-trace'} & set(argv)
        paths.extend((result, rtl_path, golden_path, argv_path, log_path))
        before = {str(p): sha(p) for p in (rtl_path, golden_path)}
        row = summarize(tracefmt.read_trace(str(golden_path)).records,
                        tracefmt.read_trace(str(rtl_path)).records)
        assert all(sha(Path(p)) == h for p,h in before.items())
        rows.append(dict(kernel=name, comparison_verdict=fields[6], **row))
    pins = {str(p): sha(p) for p in paths}
    return dict(scope='saved retirement intervals; not a new execution or stall-cause oracle',
        model_sha256=sha(model), original_gate_passed=end['canonical_gate_passed'],
        original_gate_native_exit=end['canonical_gate_native_exit'],
        original_invocation=start['invocation'], environment=env,
        gameplay_ipc=None, acceptance=False, rows=rows, pins=pins)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root, out = args.root.resolve(strict=True), args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and out.is_relative_to(scratch)
    assert not out.exists() and out.parent.is_dir()
    result = analyze(root)
    assert all(sha(Path(p)) == h for p,h in result['pins'].items())
    with out.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps(dict(kernels=len(result['rows']), pins=len(result['pins']),
                          original_gate_passed=result['original_gate_passed'], out=str(out))))


if __name__ == '__main__':
    main()
