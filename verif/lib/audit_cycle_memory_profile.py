"""Independently regrade the closed AXI wait-profile experiment; launch nothing."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO / 'verif'), str(REPO / 'verif/diff')]
import m5_metrics
import tracefmt


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def one(pattern, text):
    matches = re.findall(pattern, text, re.M)
    assert len(matches) == 1, (pattern, len(matches))
    return tuple(map(int, matches[0]))


def parse_log(text):
    assert '--l1-axi selected' in text
    assert not re.search(r'Assertion failed|%Error|%Fatal|CPU HUNG|UNIMPLEMENTED', text)
    records, clocks = one(r'^tb: retired (\d+) instructions in (\d+) clocks\b', text)
    total, u, v = one(r'^\s+retires\s+(\d+)\s+\(U=(\d+)\s+pairedV=(\d+)\)$', text)
    fill, wait, ack = one(r'^\[L1DPERF\] fill cycles=(\d+) backing-wait=(\d+) backing-ack=(\d+)$', text)
    assert total == records == u + v and records > 0 and clocks > 0
    assert fill == wait + ack and ack > 0
    return dict(records=records, clocks=clocks, u=u, v=v,
                fill_cycles=fill, backing_wait=wait, backing_ack=ack)


def validate_traces(cycle, func, stats):
    assert cycle.mode == 'cycle' and func.mode == 'func'
    # Cycle-only records contain no x87 payload even with --x87; the full
    # architectural stream's header (checked against argv below) owns that mode.
    cr, fr = cycle.records, func.records
    assert len(cr) == len(fr) == stats['records']
    required = set(tracefmt.GPR_KEYS + tracefmt.SEG_KEYS + ['n', 'pc', 'eflags'])
    if func.x87:
        required.update(tracefmt.X87_REGS + tracefmt.X87_CTL)
    for i, (c, f) in enumerate(zip(cr, fr)):
        assert c['n'] == f['n'] == i and c['pc'] == f['pc']
        assert required <= f.keys(), 'architectural payload absent'
        assert c['pipe'] in ('U', 'V') and c['paired'] == (c['pipe'] == 'V')
        assert c['cyc'] > 0 and (not i or c['cyc'] >= cr[i - 1]['cyc'])
        if c['pipe'] == 'V':
            assert i and cr[i - 1]['pipe'] == 'U' and cr[i - 1]['cyc'] == c['cyc']
    assert cr[-1]['cyc'] == stats['clocks']
    assert sum(r['pipe'] == 'V' for r in cr) == stats['v']


def audit(root):
    started, closed = load(root / 'started.json'), load(root / 'closed.json')
    assert closed['diagnostic_completed'] and closed['pins_unchanged'] and not closed['errors']
    assert not any(closed[k] for k in ('canonical_gate_passed', 'standard_suite', 'physical_board'))
    assert closed['gameplay_ipc'] is None
    assert all(closed['memory_events'][k] == '0' for k in ('oom', 'oom_kill', 'oom_group_kill'))
    pins = started['pins']
    assert all(sha(p) == h for p, h in pins.items())
    owner = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', 'ventium-cycle-memory-profile-oct15-r1.service',
        '-pMainPID', '-pSubState', '-pInvocationID', '-pExecMainStatus', '-pResult'],
        text=True, timeout=5).splitlines())
    assert owner == dict(MainPID='0', SubState='exited', ExecMainStatus='0',
                         Result='success', InvocationID=started['invocation'])
    assert started['added_waits'] == [0, 7] and started['modes'] == ['cycle', 'cycle-func']
    assert started['affinity'] == [13]
    model = next(Path(p) for p in pins if p.endswith('/obj/tb_ventium'))
    assert sha(model) == started['model_sha256']
    core = model.parent.parent
    assert load(core / 'build-started.json')['definitions'] == started['definitions']
    old = core / 'generic-work'
    names = sorted(p.name.removesuffix('.cycle.result') for p in old.glob('*.cycle.result'))
    assert len(names) == 20 and sorted(r['name'] for r in closed['rows']) == names
    assert len(list(root.glob('*.native.json'))) == 80
    rows = []
    for name in names:
        raw = (old / (name + '.cycle_rtl.argv')).read_bytes().split(b'\0')
        assert raw.pop() == b''
        template = [s.decode() for s in raw]
        assert template[0] == str(model) and template.count('--cycle') == 1
        assert '--l1-axi' in template
        assert not {'--dbg-step', '--dbg-bp', '--no-trace'} & set(template)
        observations = {}
        for latency in (0, 7):
            for mode in ('cycle', 'cycle-func'):
                tag = f'{name}.lat{latency}.{mode}'
                native = load(root / (tag + '.native.json'))
                expected = template.copy()
                expected[expected.index('--cycle')] = '--' + mode
                expected[expected.index('--out') + 1] = str(root / (tag + '.vtrace'))
                assert native['argv'] == expected
                assert native['environment'] == dict(AXI_RLAT=str(latency), AXI_WLAT=str(latency))
                assert native['exit'] == 0 and native['actual_wait'] and native['proc_gone']
                assert native['affinity_observed'] and native['affinity'] == [13]
                assert 0 < native['seconds'] < 60
                stats = parse_log((root / (tag + '.log')).read_text())
                observations[latency, mode] = (tracefmt.read_trace(str(root / (tag + '.vtrace'))), stats)
            cycle, stats = observations[latency, 'cycle']
            func, fstats = observations[latency, 'cycle-func']
            assert func.x87 == ('--x87' in template)
            assert stats == fstats
            validate_traces(cycle, func, stats)
        assert observations[0, 'cycle-func'][0].records == observations[7, 'cycle-func'][0].records
        assert observations[7, 'cycle'][0].records == tracefmt.read_trace(str(old / (name + '.cycle_rtl.vtrace'))).records
        assert observations[7, 'cycle'][1] == parse_log((old / (name + '.cycle_rtl.log')).read_text())
        original = next(r for r in closed['rows'] if r['name'] == name)
        row = dict(name=name, latency0=observations[0, 'cycle'][1], latency7=observations[7, 'cycle'][1],
                   full_architecture_equal=True, latency7_canonical_repeat_identical=True,
                   golden=(old / (name + '.cycle.result')).read_text().strip().split('|')[5])
        for latency in (0, 7):
            chain = parse_log((root / f'mb_faddchain.lat{latency}.cycle.log').read_text())
            os.environ['M5_FADDCHAIN_CPI'] = str(chain['clocks'] / chain['records'])
            row[f'metrics{latency}'] = list(m5_metrics.compute(name,
                str(root / f'{name}.lat{latency}.cycle.vtrace'), row['golden'], 10))
        assert row == original, name
        rows.append(row)
    assert all(sha(p) == h for p, h in pins.items())
    artifacts = {str(p): sha(p) for p in root.iterdir() if p.is_file()}
    artifacts[str(Path(__file__).resolve())] = sha(__file__)
    return dict(passed=True, pins_checked=len(pins), owner=owner, native_runs=80,
        paired_v_per_latency=sum(r['latency0']['v'] for r in rows),
        architectural_records_compared=sum(r['latency0']['records'] for r in rows),
        verdicts={str(lat): dict(Counter(r[f'metrics{lat}'][0] for r in rows)) for lat in (0, 7)},
        wait_cost_residuals={r['name']: r['latency7']['clocks'] - r['latency0']['clocks']
                            - 7 * r['latency0']['backing_ack'] for r in rows},
        artifacts=artifacts, canonical_gate_passed=False, standard_suite=False,
        physical_board=False, gameplay_ipc=None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    root, out = args.run.resolve(strict=True), args.out.resolve()
    assert root.is_relative_to(scratch) and out.is_relative_to(scratch) and not out.exists()
    result = audit(root)
    with out.open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps({k: v for k, v in result.items() if k != 'artifacts'}, indent=2))


if __name__ == '__main__':
    main()
