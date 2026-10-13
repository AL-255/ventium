"""Independently recompare the closed composed model's SMSW matrices.

Require complete trace equality to the independently audited isolated repair
and rerun the unchanged QEMU comparator. Preserve all 20 oracle disagreements.
This does not qualify the canonical gate, timing, standard suite or hardware.
"""
import argparse
import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys

import compose_prime_reg as composition
from run_combined_retry import MODEL

REPO, sha = composition.REPO, composition.sha
sys.path.insert(0, str(REPO/'verif/diff'))
import tracefmt


def owner(unit, invocation, status):
    props = dict(s.split('=', 1) for s in subprocess.check_output([
        'systemctl', '--user', 'show', unit, '-p', 'MainPID', '-p', 'InvocationID',
        '-p', 'SubState', '-p', 'ExecMainStatus'], text=True, timeout=5).splitlines())
    assert props == dict(MainPID='0', InvocationID=invocation,
                         SubState='failed' if status else 'exited', ExecMainStatus=str(status))
    return props


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root, out = args.evidence.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and out.is_relative_to(scratch)
    assert not out.exists()
    core = root/'smsw-prime-reg-core-r1'
    build = json.loads((core/'build-closed.json').read_text())
    wrapper = json.loads((core/'combined-build-closed.json').read_text())
    assert build['passed'] and build['pins_unchanged'] and build['native_exit'] == 0
    assert wrapper['passed'] and wrapper['wrapper_pins_unchanged']
    assert sha(core/'obj/tb_ventium') == build['binary_sha256'] == wrapper['binary_sha256'] == MODEL
    owners = {'build': owner('ventium-smsw-prime-reg-core-oct13-r1.service',
                             '2dfac73fbc1a45e99365c944f0c4b1f0', 0)}
    pins = {}

    def pin(path):
        pins[str(path)] = sha(path)

    def inputs(receipt):
        for p, digest in receipt['pins'].items():
            assert sha(p) == digest
            assert p not in pins or pins[p] == digest
            pins[p] = digest

    for name in ('prepared.json', 'build-started.json', 'combined-build-started.json'):
        path = core/name
        inputs(json.loads(path.read_text()))
        pin(path)
    for path in (core/'build-closed.json', core/'combined-build-closed.json', core/'obj/tb_ventium',
                 Path(__file__).resolve(), Path(composition.__file__), REPO/'verif/diff/compare.py',
                 REPO/'verif/diff/tracefmt.py'):
        pin(path)
    for name, digest in composition.AUDITS.items():
        path = root/name
        assert sha(path) == digest
        audit = json.loads(path.read_text())
        composition.check_audit(name, audit)
        inputs(audit)
        pin(path)
    matrices = [
        ('diff', 'smsw-diff-r1', 88), ('privilege', 'smsw-privilege-r2', 60),
        ('fault', 'smsw-fault-r1', 45),
        *((f'retry-l{lat}', f'smsw-retry-l{lat}-r1', 25) for lat in (0, 7, 31)),
    ]
    work = []
    for label, oldname, count in matrices:
        new, old = root/f'smsw-prime-reg-{label}-r1', root/oldname
        before = json.loads((new/'started.json').read_text())
        done, prior = (json.loads((p/'closed.json').read_text()) for p in (new, old))
        assert done['pins_unchanged'] and not done['errors']
        assert done['passed'] == (label != 'fault')
        assert len(done['rows']) == len(prior['rows']) == count
        inputs(before)
        owners[label] = owner(f'ventium-smsw-prime-reg-{label}-oct13-r1.service', before['invocation'],
                              1 if label == 'fault' else 0)
        for p in (new/'started.json', new/'closed.json', old/'closed.json'):
            pin(p)
        prior_rows = {r['name']: r for r in prior['rows']}
        assert len(prior_rows) == count and {r['name'] for r in done['rows']} == prior_rows.keys()
        if label == 'diff':
            for p, digest in done['artifacts'].items():
                assert sha(p) == digest
                pins[p] = digest
        for row in done['rows']:
            name, earlier = row['name'], prior_rows[row['name']]
            assert row['records'] == earlier['records']
            if label == 'diff':
                candidate, previous = new/(name+'.vtrace'), old/(name+'.vtrace')
                golden = root/'smsw-golden-r2'/(name+'.vtrace')
                assert row['native_exit'] == 133 and sha(candidate) == row['trace_sha256']
                native = json.loads((new/(name+'.native.json')).read_text())
                assert native['exit'] == 133 and native['observed']
                expected = 0
            else:
                assert row['case'] == earlier['case']
                for p, digest in row['artifacts'].items():
                    assert sha(p) == digest
                    pins[p] = digest
                candidate, previous = new/name/'candidate.vtrace', old/name/'candidate.vtrace'
                golden = new/name/'golden.vtrace'
                native = json.loads((new/name/'candidate-native.json').read_text())
                assert native['exit'] == 133 and native['observed_affinity']
                expected = 1 if label == 'fault' and row['case']['CASE'] < 4 else 0
                assert row['passed'] == (expected == 0)
                if expected:
                    assert row['qemu_native_exit'] == 135 and row['rtl_native_exit'] == 133
            for p in (candidate, previous, golden):
                pin(p)
            work.append((label, name, candidate, previous, golden, expected))

    def compare(item):
        label, name, candidate, previous, golden, expected = item
        a, b = (tracefmt.read_trace(str(p)) for p in (candidate, previous))
        assert a.sys and b.sys and a.mode == b.mode == 'func' and not a.x87 and not b.x87
        assert a.records == b.records, (label, name, 'complete isolated/composed state differs')
        assert int(a.records[-1]['eax'], 16) & 255 == 0x42
        result = subprocess.run([sys.executable, '-B', REPO/'verif/diff/compare.py',
                                 '--mode', 'func', golden, candidate], capture_output=True, text=True, timeout=10)
        assert result.returncode == expected, (label, name, result.stdout, result.stderr)
        if expected == 0:
            assert 'sys compared: True' in result.stdout and 'RESULT: EQUIVALENT' in result.stdout
        else:
            assert 'field=esp:' in result.stdout
        return dict(matrix=label, name=name, records=len(a.records), comparator_exit=expected,
                    isolated_composed_full_records_equal=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        rows = list(pool.map(compare, work))
    assert len(rows) == 268 and sum(r['comparator_exit'] == 0 for r in rows) == 248
    assert all(sha(p) == digest for p, digest in pins.items())
    result = dict(audit_passed=True, model_sha256=MODEL, owners=owners, pins=pins, rows=rows,
        differential_cases=248, intel_spec_only_cases=20,
        complete_fault_differential_gate_passed=False, canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None, fmax_mhz=None)
    with out.open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps({k: v for k, v in result.items() if k not in ('pins', 'rows')}), flush=True)


if __name__ == '__main__':
    main()
