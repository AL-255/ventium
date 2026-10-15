"""Regrade complete authenticated-golden and same-input corpus artifacts.

Retain canonical failures and the three pre-existing x87 mask cases. Neither
PASS text, truncated traces nor the new transport alone establishes this audit.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sys

from run_fetch_fragment_owned import DATA, MODEL, REPO

sys.path.insert(0, str(REPO/'verif/sys/fp_env_store'))
import audit_write_regressions as existing

sha, load, equivalent, tracefmt = existing.sha, existing.load, existing.equivalent, existing.tracefmt


def main():
    assert Path(os.environ['TMPDIR']).resolve() == Path('/home/yukidama/external/tmp').resolve()
    root = DATA.resolve()
    func = root/'fetch-fragment-owned-func-r2'
    replay = root/'fetch-fragment-owned-same-input-r1'
    core = root/'fetch-fragment-core-r1'
    parent = root/'prefix-payload-core-r1'
    fs, fc = load(func/'started.json'), load(func/'closed.json')
    rs, rc = load(replay/'started.json'), load(replay/'closed.json')
    vc = load(core/'verify-closed.json')
    assert fc['passed'] and fc['pins_unchanged'] and len(fc['rows']) == 108
    assert rc['passed'] and rc['pins_unchanged'] and len(rc['rows']) == 108 and not rc['errors']
    for receipt in (fc, rc):
        assert all(receipt['memory_events'][key] == '0' for key in ('oom', 'oom_kill', 'oom_group_kill'))
    pins = dict(fs['pins'])
    for path, digest in rs['pins'].items():
        assert path not in pins or pins[path] == digest
        pins[path] = digest
    assert all(sha(path) == digest for path, digest in pins.items())
    assert sha(core/'obj/tb_ventium') == fs['model'] == MODEL
    assert fs['environment']['TB_EXTRA_FLAGS'] == '--cycle-func --l1-axi'
    assert fs['environment']['AXI_RLAT'] == fs['environment']['AXI_WLAT'] == '7'
    assert vc['canonical_gate_native_exit'] == 2 and not vc['canonical_gate_passed']
    assert vc['pins_unchanged'] and not vc['masks_or_goldens_or_bands_changed']
    goldens = {}
    for path in (func/'private-enabled-cache').glob('*.vtrace'):
        trace = tracefmt.read_trace(str(path))
        name = re.search(r'elf=(\w+)\.func\.elf ', trace.hdr['note'])[1]
        assert name not in goldens and '.producer' in path.name
        goldens[name] = path
    assert len(goldens) == 108
    records = paired = parent_paired = 0
    unmasked = []
    for job, row, replay_row in zip(fs['jobs'], fc['rows'], rc['rows']):
        name = job[1]
        assert row['name'] == replay_row['name'] == name
        assert row['passed'] and row['actual_wait'] and row['affinity_verified']
        assert row['error'] is None and row['native_worker_exit'] == 0
        cpu = int(row['command'][2])
        assert 13 <= cpu <= 16
        assert {v['executable'] for v in row['observed_affinity'].values()} == {'qemu-i386', 'tb_ventium'}
        assert all(v['affinity'] == [cpu] for v in row['observed_affinity'].values())
        rtl = func/'work'/(name+'.func_rtl.vtrace')
        golden = goldens[name]
        r, g = tracefmt.read_trace(str(rtl)), tracefmt.read_trace(str(golden))
        assert len(r.records) == len(g.records) and r.x87 == g.x87 == bool(int(job[6]))
        assert r.records == tracefmt.read_trace(str(replay/name/'parent.vtrace')).records
        assert r.records == tracefmt.read_trace(str(replay/name/'candidate.vtrace')).records
        assert replay_row['passed'] and replay_row['counts']['parent'] == replay_row['counts']['candidate']
        assert len(replay_row['native']) == 2
        for native in replay_row['native']:
            assert native['native_exit'] == 0 and native['actual_wait'] and native['affinity_verified']
            assert native['error'] is None
            assert '--cycle-func' in native['command'] and '--l1-axi' in native['command']
            assert not {'--dbg-step', '--dbg-bp'} & set(native['command'])
        records += len(r.records)
        # Same manifest-defined policies as the original independent audit.
        manifest = load(Path(job[2]).parent/'manifest.json')
        options = []
        def fmt(value):
            return f'{value[0]}:{"" if len(value)<2 or value[1] is None else value[1]}' + (
                f'={value[2]}' if len(value)>=3 and value[2] else '')
        for key, mask in (('x87_fprem1_cc_ranges','0x4300'), ('x87_stkflt_fstat_ranges','0x4741')):
            if manifest.get(key):
                options += ['--mask-fstat-exc', mask]
                for value in manifest[key]: options += ['--mask-fstat-range', fmt(value)]
        for value in manifest.get('x87_stkflt_fpr_ranges', []):
            options += ['--mask-fpr-range', fmt(value)]
        if not options and manifest.get('x87_stkflt_arch'):
            options += ['--mask-fstat-exc','0x4741','--mask-x87-fpr']
        assert equivalent(golden, rtl, options)
        if not equivalent(golden, rtl): unmasked.append(name)
        logs = [(func/'work'/(name+'.func_rtl.log')).read_text(),
                (replay/name/'parent.log').read_text(), (replay/name/'candidate.log').read_text()]
        counts = []
        for log in logs:
            assert '--l1-axi selected' in log
            assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED', log)
            counts.append((int(re.search(r'^  clocks\s+(\d+)', log, re.M)[1]),
                           int(re.search(r'pairedV=(\d+)', log)[1])))
        assert counts[0] == counts[1] == counts[2]
        paired += counts[0][1]; parent_paired += counts[1][1]
    assert records == rc['records'] == 80800 and paired == parent_paired == 30132
    assert set(unmasked) == {'tx_regform', 'tx_regform2', 'tx_stack'}
    old = sorted((parent/'generic-work').glob('*.cycle_rtl.vtrace'))
    new = sorted((core/'generic-work').glob('*.cycle_rtl.vtrace'))
    assert len(old) == len(new) == len(vc['deltas']) == 20
    assert all(row['same_records'] for row in vc['deltas'])
    for a, b in zip(old, new):
        assert a.name == b.name and tracefmt.read_trace(str(a)).records == tracefmt.read_trace(str(b)).records
    verdicts = [p.read_text().strip().split('|')[3] for p in (core/'generic-work').glob('*.func.result')]
    assert len(verdicts) == 108 and verdicts.count('PASS') == 7 and verdicts.count('FAIL') == 101
    assert all(sha(path) == digest for path, digest in pins.items())
    artifacts = {str(path): sha(path) for directory in (func, replay, core/'generic-work')
                 for path in directory.rglob('*') if path.is_file()}
    for path in (Path(__file__), Path(existing.__file__), core/'verify-closed.json',
                 Path(tracefmt.__file__), *old):
        artifacts[str(path)] = sha(path)
    report = dict(audit_passed=True, functional_passes=108, unmasked_functional_passes=105,
        unmasked_failures=unmasked, functional_records=records, v_retirements=paired,
        parent_v_retirements=parent_paired, pair_deltas=[], cycle_traces_unchanged=20,
        canonical_gate_native_exit=2, canonical_gate_passed=False,
        canonical_functional_passes=7, canonical_functional_failures=101,
        artifacts=artifacts, pins_checked=len(pins), standard_suite=False,
        physical_board=False, gameplay_ipc=None)
    with (root/'fetch-fragment-regression-audit.json').open('x') as stream:
        json.dump(report, stream, indent=2)
    print(json.dumps({k:v for k,v in report.items() if k != 'artifacts'}), flush=True)


if __name__ == '__main__':
    main()
