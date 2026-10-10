"""Observe the real I-cache flush contract on sealed cold A/B fixtures.

No recompilation, altered RAM, architectural trace filtering or golden edits.
The already differential-tested fixture is rerun with a read-only RTL probe.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO / 'verif/diff'))
import tracefmt


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as f:
        json.dump(value, f, indent=2)


def grade(text, minimum_nonempty=16):
    events = [s for s in text.splitlines() if s.startswith('[ICFL]')]
    blocks, current, reported = [], None, []
    for event in events:
        if event == '[ICFL] flush':
            current = []; blocks.append(current)
        elif event.startswith('[ICFL] flush_all edges seen: '):
            reported.append(int(event.rsplit(' ', 1)[1]))
        elif current is not None:
            current.append(event)
    assert reported == [len(blocks)] and len(blocks) >= minimum_nonempty
    nonempty = refilled = 0
    for block in blocks:
        occupied, emptied, fills = set(), set(), set()
        for event in block:
            if m := re.fullmatch(r'\[ICFL\] pre set=(\d+) way=(\d+) tag=([0-9a-f]+) ptag=([0-9a-f]+)', event):
                assert not emptied, 'pre occupancy after post edge'
                occupied.add(int(m[1]))
            elif m := re.fullmatch(r'\[ICFL\] post set=(\d+) valid=([01]+)', event):
                index = int(m[1])
                assert index in occupied and index not in emptied and set(m[2]) == {'0'}
                emptied.add(index)
            elif m := re.fullmatch(r'\[ICFL\] fill set=(\d+) way=(\d+) tag=([0-9a-f]+) ptag=([0-9a-f]+)', event):
                index = int(m[1])
                assert index not in occupied or index in emptied, 'refill before empty proof'
                if index in occupied:
                    fills.add(index)
            else:
                raise AssertionError('unrecognized probe record: ' + event)
        assert occupied == emptied, 'missing post-edge empty proof'
        nonempty += bool(occupied)
        refilled += bool(fills)
    assert nonempty >= minimum_nonempty and refilled >= minimum_nonempty
    return dict(flushes=len(blocks), nonempty_flushes=nonempty, refilled_flushes=refilled), events


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--matrix', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert a.out.resolve().is_relative_to(scratch) and shutil.disk_usage(scratch).free > 2*1024**3
    started = json.loads((a.matrix/'started.json').read_text())
    closed = json.loads((a.matrix/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['all_children_reaped']
    assert len(closed['measurements']) == 1536 and all(d['saved_clocks'] == 0 for d in closed['deltas'])
    pins = dict(started['pins'])
    assert all(sha(f) == h for f, h in pins.items())
    cases = [f'k{k}-r{r}-o{o}' for k in range(6) for r in (0, 1) for o in (0, 27, 30, 31)]
    for name in cases:
        leaf = a.matrix/name
        receipt = json.loads((leaf/'closed.json').read_text())
        assert receipt['passed'] and sha(leaf/'fixture.bin') == receipt['image_sha256']
        for path in [leaf/'closed.json', leaf/'fixture.bin'] + list(leaf.glob('*-cycle.vtrace')):
            pins[str(path)] = sha(path)
    for path in (Path(__file__), a.matrix/'started.json', a.matrix/'closed.json'):
        pins[str(path)] = sha(path)
    a.out.mkdir()
    save(a.out/'started.json', dict(pins=pins, cases=cases, invocation=os.environ.get('INVOCATION_ID')))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VTM_', 'TB_', 'QEMU_', 'AXI_'))}
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    def check(name):
        leaf = a.out/name; leaf.mkdir()
        observations = []
        for latency in (0, 7):
            event_lists = []
            for label, model in started['models'].items():
                stem = f'{label}-lat{latency}'
                trace = leaf/(stem+'.vtrace')
                command = ['timeout', '--signal=TERM', '--kill-after=3s', '20s', model,
                    '--system', '--cosim', '--cycle', '--l1-axi', '--image', str(a.matrix/name/'fixture.bin'),
                    '--out', str(trace), '--max-insn', '2000', '--max-cycles', '1000000',
                    '--quiesce', '4096', '+ven_icflushlog', '+ven_faultlog']
                save(leaf/(stem+'.command.json'), command)
                with (leaf/(stem+'.out')).open('x') as out, (leaf/(stem+'.err')).open('x') as err:
                    child = subprocess.run(command, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                                           stdout=out, stderr=err)
                save(leaf/(stem+'.exit.json'), dict(native_exit=child.returncode))
                assert child.returncode == 133
                text = (leaf/(stem+'.out')).read_text()
                assert not re.search(r'%Error|%Fatal|Assertion|ICACHE/FLUSH|ICACHE/DUP-TAG', text)
                reference = a.matrix/name/f'{label}-lat{latency}-cycle.vtrace'
                assert tracefmt.read_trace(str(trace)).records == tracefmt.read_trace(str(reference)).records
                stats, events = grade(text)
                observations.append(dict(model=label, latency=latency, **stats))
                event_lists.append(events)
            assert event_lists[0] == event_lists[1], 'entire flush/fill probe streams differ'
        save(leaf/'closed.json', dict(passed=True, observations=observations))
        return observations
    begin = time.monotonic(); result = dict(passed=False, errors=[], observations=[])
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            for future in concurrent.futures.as_completed([pool.submit(check, c) for c in cases]):
                try:
                    result['observations'].extend(future.result())
                except Exception as error:
                    result['errors'].append(repr(error))
        assert len(result['observations']) == len(cases)*4 and not result['errors']
        result['passed'] = True
    except Exception as error:
        result['errors'].append(repr(error))
    result.update(seconds=time.monotonic()-begin, pins_unchanged=all(sha(f)==h for f,h in pins.items()),
                  full_standard_suite=False, gameplay_ipc=None)
    result['passed'] &= result['pins_unchanged']
    save(a.out/'closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k!='observations'}))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
