"""Independently check the single-fill model, functional corpus and cycle sweep."""
import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO / 'verif'), str(REPO / 'verif/diff')]
import compare
import m5_metrics
import tracefmt


def load(path):
    return json.loads(path.read_text())


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def same_func(gold, rtl, options=()):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return compare.main(['--mode', 'func', *options, str(gold), str(rtl)]) == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    assert __debug__ and os.sched_getaffinity(0) == {12}
    assert not (root / 'audit.json').exists()
    owners, pins = {}, {}
    names = {
        'profile-r2': 'ventium-cycle-backend-profile-oct13-r2',
        'board-core-r1': 'ventium-cycle-board-build-oct13-r1',
        'board-profile-r1': 'ventium-cycle-board-profile-oct13-r1',
        'board-func-r1': 'ventium-cycle-board-func-oct13-r1',
        'complete-r3': 'ventium-cycle-complete-oct13-r3',
    }
    for label, unit in names.items():
        build = label == 'board-core-r1'
        started = load(root / label / ('build-started.json' if build else 'started.json'))
        closed = load(root / label / ('build-closed.json' if build else 'closed.json'))
        command = ['systemctl', '--user', 'show', unit + '.service']
        for key in ('MainPID', 'SubState', 'InvocationID', 'ExecMainStatus', 'MemoryPeak',
                    'ExecMainStartTimestampMonotonic', 'ExecMainExitTimestampMonotonic'):
            command += ['-p', key]
        owner = dict(s.split('=', 1) for s in subprocess.check_output(command, text=True).splitlines())
        assert owner['MainPID'] == '0' and owner['SubState'] == 'exited' and owner['ExecMainStatus'] == '0'
        assert closed['pins_unchanged'] and closed.get('passed', closed.get('diagnostic_completed'))
        if build:
            events = [json.loads(s) for s in subprocess.check_output(['journalctl', '--user', '--no-pager',
                '-o', 'json', 'USER_INVOCATION_ID=' + started['invocation']], text=True).splitlines()]
            begin = [e for e in events if e.get('USER_UNIT') == 'ventium-ipc-parallel32.scope' and e.get('JOB_TYPE') == 'start']
            end = [e for e in events if e.get('USER_UNIT') == 'ventium-ipc-parallel32.scope' and 'MEMORY_PEAK' in e]
            assert len(begin) == len(end) == 1 and root.name in begin[0]['MESSAGE']
            assert int(owner['ExecMainStartTimestampMonotonic']) <= int(begin[0]['__MONOTONIC_TIMESTAMP']) < int(end[0]['__MONOTONIC_TIMESTAMP']) <= int(owner['ExecMainExitTimestampMonotonic'])
            owner.update(scope_invocation=started['invocation'], scope_memory_peak=end[0]['MEMORY_PEAK'],
                         scope_swap_peak=end[0].get('MEMORY_SWAP_PEAK'))
        else:
            assert owner['InvocationID'] == started['invocation']
            assert closed['memory_events']['oom'] == closed['memory_events']['oom_kill'] == '0'
        for path, digest in started['pins'].items():
            assert path not in pins or pins[path] == digest
            pins[path] = digest
        owners[label] = owner
    assert all(sha(p) == h for p, h in pins.items())
    core = root / 'board-core-r1'
    start = load(core / 'build-started.json')
    parent = Path(start['parent'])
    files = [p for p in (core / 'candidate').rglob('*') if p.is_file()]
    assert len(files) == 195 and all(sha(p) == sha(parent / 'candidate' / p.relative_to(core / 'candidate')) for p in files)
    assert start['changes'] == [] and start['parameter_delta'] == {'AXI_LINE_REPLAY': [1, 0]}
    assert sha(start['host']) == sha(load(parent / 'build-started.json')['host'])
    native = (core / 'obj/Vventium_top__verFiles.dat').read_text()
    assert native.count('-GAXI_LINE_REPLAY=0') == 1
    assert set(re.findall(r'\+define\+(\w+)', native)) == set(start['definitions']) and len(start['definitions']) == 152
    assert sha(core / 'obj/tb_ventium') == load(core / 'build-closed.json')['binary_sha256']
    host = Path(start['host'])
    assert (core / 'obj' / (host.stem + '.o')).is_file()
    deps = (core / 'obj' / (host.stem + '.d')).read_text().replace('\\\n', ' ').split()
    header = [Path(s) for s in deps if Path(s).name == 'Vventium_top___024root.h']
    assert len(header) == 1
    assert (header[0] if header[0].is_absolute() else core / 'obj' / header[0]).resolve() == (core / 'obj/Vventium_top___024root.h').resolve()
    phase_rows = {}
    for phase, count in (('profile-r2', 24), ('board-profile-r1', 24), ('complete-r3', 40)):
        rows = load(root / phase / 'closed.json')['rows']
        assert len(rows) == count
        phase_rows[phase] = {(r['name'], r['latency']): r for r in rows}
        for row in rows:
            name, latency = row['name'], row['latency']
            label = name + '-lat' + str(latency)
            trace, log = root / phase / (label + '.vtrace'), root / phase / (label + '.log')
            assert sha(trace) == row['trace_sha256'] and sha(log) == row['log_sha256']
            records = tracefmt.read_trace(str(trace)).records
            old = parent / 'generic-work' / (name + '.cycle_rtl.vtrace')
            # Cycle traces contain PC/order/pipe/clocks, not architectural
            # registers. Never present this check as functional equivalence.
            old_records = tracefmt.read_trace(str(old)).records
            assert [(r['n'], r['pc']) for r in records] == [(r['n'], r['pc']) for r in old_records]
            assert len(records) == row['records'] and records[-1]['cyc'] == row['clocks']
            assert sum(r['pipe'] == 'V' for r in records) == row['paired_v']
            assert row['native_exit'] == 0 and row['affinity_observed'] and row['affinity'] == [int(row['command'][2])]
            if phase == 'profile-r2' and latency == 7:
                assert records == tracefmt.read_trace(str(old)).records
            axi = row['axi']
            assert axi['overlap'] == axi['orphan_r'] == 0
            if axi['valid']:
                assert axi['incomplete'] == 0 and axi['r'] == 8 * axi['ar'] and axi['rlast'] == axi['ar']
            else:
                assert phase == 'complete-r3' and name == 'mb_agiloop' and axi['incomplete'] == 1
                assert 'avg_busy' not in axi
    for key, row in phase_rows['board-profile-r1'].items():
        old = phase_rows['profile-r2'][key]
        assert old['axi']['ar'] == 2 * row['axi']['ar'] and old['paired_v'] == row['paired_v']
        if key in phase_rows['complete-r3']:
            repeated = phase_rows['complete-r3'][key]
            assert repeated['trace_sha256'] == row['trace_sha256']
    bands = load(root / 'complete-r3/bands.json')['bands']
    for row in bands:
        name, latency = row['name'], row['latency']
        chain = phase_rows['complete-r3'][('mb_faddchain', latency)]
        os.environ['M5_FADDCHAIN_CPI'] = str(chain['cpi'])
        gold = (parent / 'generic-work' / (name + '.cycle.result')).read_text().split('|')[5]
        actual = m5_metrics.compute(name, str(root / 'complete-r3' / (name + '-lat' + str(latency) + '.vtrace')), gold, 10.0)
        assert list(actual) == [row[k] for k in ('verdict', 'cpi', 'pair', 'extra', 'detail')]
    func = root / 'board-func-r1'
    fs, fc = load(func / 'started.json'), load(func / 'closed.json')
    assert len(fc['rows']) == len(fs['jobs']) == 108 and all(r['passed'] for r in fc['rows'])
    goldens = {}
    for path in (func / 'private-enabled-cache').glob('*.vtrace'):
        name = re.search(r'elf=(\w+)\.func\.elf ', tracefmt.read_trace(str(path)).hdr['note']).group(1)
        assert name not in goldens
        goldens[name] = path
    assert len(goldens) == 108
    records = paired = raw_passes = 0
    for job, row in zip(fs['jobs'], fc['rows']):
        name = job[1]
        assert row['name'] == name and row['native_worker_exit'] == 0 and row['actual_wait'] and row['error'] is None
        assert row['affinity_verified']
        assert {r['executable'] for r in row['observed_affinity'].values()} == {'tb_ventium', 'qemu-i386'}
        assert all(r['affinity'] == [int(row['command'][2])] for r in row['observed_affinity'].values())
        rtl = func / 'work' / (name + '.func_rtl.vtrace')
        manifest = load(Path(job[2]).parent / 'manifest.json')
        options = []
        def fmt(value):
            return str(value[0]) + ':' + ('' if len(value) < 2 or value[1] is None else str(value[1])) + (('=' + str(value[2])) if len(value) >= 3 and value[2] else '')
        for key, mask in (('x87_fprem1_cc_ranges', '0x4300'), ('x87_stkflt_fstat_ranges', '0x4741')):
            if manifest.get(key):
                options += ['--mask-fstat-exc', mask]
                for value in manifest[key]: options += ['--mask-fstat-range', fmt(value)]
        for value in manifest.get('x87_stkflt_fpr_ranges', []): options += ['--mask-fpr-range', fmt(value)]
        if not options and manifest.get('x87_stkflt_arch'):
            options += ['--mask-fstat-exc', '0x4741', '--mask-x87-fpr']
        assert same_func(goldens[name], rtl, options)
        raw_passes += same_func(goldens[name], rtl)
        records += len(tracefmt.read_trace(str(rtl)).records)
        log = (func / 'work' / (name + '.func_rtl.log')).read_text()
        assert '--l1-axi selected' in log
        paired += int(re.search(r'pairedV=(\d+)', log).group(1))
    assert (records, paired, raw_passes) == (80800, 30134, 105)
    imiss_log = (root / 'complete-r3/mb_imiss-lat0.log').read_text()
    states = {int(n): int(v) for n, v in re.findall(r'^    state +(\d+) +(\d+) +[\d.]+%', imiss_log, re.M)}
    assert sum(states.values()) == 34170 and states == {0: 1, 2: 1, 8: 1, 27: 14070, 28: 20097}
    bails = {int(n): int(v) for n, v in re.findall(r'^    \[ *(\d+)\] +(\d+) +[\d.]+%', imiss_log, re.M)}
    assert sum(bails.values()) == states[28] and bails == {1: 10052, 2: 2010, 9: 1, 10: 6023, 12: 2011}
    imiss_partition = dict(reset_decode=3, refill_words=14070, missing_bytes=10052,
        registered_icache_read=2010, slow_decode_handoff=1, branch_penalty=6023, issue=2011)
    assert sum(imiss_partition.values()) == 34170
    artifacts = {str(p): sha(p) for phase in names for p in (root / phase).rglob('*') if p.is_file() and phase != 'board-core-r1'}
    result = dict(audit_passed=True, owners=owners, input_pins=len(pins), source_files=195,
        rtl_changes=[], parameter_delta=start['parameter_delta'], functional_passes=108,
        unmasked_functional_passes=raw_passes, functional_records=records, functional_v_retirements=paired,
        cycle_runs=88, bands=bands, imiss_clock_partition=imiss_partition, artifacts=artifacts, canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None, fmax_mhz=None)
    with (root / 'audit.json').open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps({k: v for k, v in result.items() if k not in ('artifacts', 'bands')}, indent=2))


if __name__ == '__main__':
    main()
