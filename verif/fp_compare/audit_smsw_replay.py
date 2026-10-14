"""Independently regrade the closed latest-core SMSW replays; no suite claim."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
ROOT = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve(strict=True)
OLD = ROOT.parent / 'ventium-load-read-ack.GyWDDtiI'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def owner(unit, invocation):
    value = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', unit, '-p', 'ActiveState', '-p', 'SubState',
        '-p', 'MainPID', '-p', 'InvocationID', '-p', 'ExecMainStatus'], text=True).splitlines())
    assert value == dict(ActiveState='active', SubState='exited', MainPID='0',
                         InvocationID=invocation, ExecMainStatus='0')
    return value


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == ROOT.parent
    core = ROOT / 'fp-compare-core-r1'
    model = core / 'obj/tb_ventium'
    assert sha(model) == '5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8'
    built, begun = load(core / 'build-closed.json'), load(core / 'build-started.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(model) and len(begun['definitions']) == 152
    pins = dict(begun['pins'])
    for path in (Path(__file__), model, core / 'build-started.json', core / 'build-closed.json',
                 REPO / 'verif/diff/compare.py', REPO / 'verif/diff/tracefmt.py'):
        pins[str(path)] = sha(path)
    counts, owners = {}, {}
    v_retirements = backing_acks = 0
    compare_count = records = 0

    def compare(golden, actual):
        result = subprocess.run([sys.executable, '-B', str(REPO / 'verif/diff/compare.py'),
            '--mode', 'func', str(golden), str(actual)], text=True, capture_output=True, timeout=10)
        assert result.returncode == 0 and 'RESULT: EQUIVALENT' in result.stdout
        assert 'sys compared: True' in result.stdout

    for leaf, unit, count in (
        ('fp-compare-smsw-r1', 'ventium-fp-compare-smsw-oct14-r1.service', 88),
        ('fp-compare-smswcorners-r2', 'ventium-fp-compare-smswcorners-oct14-r2.service', 135),
    ):
        root = ROOT / leaf
        start, closed = load(root / 'started.json'), load(root / 'closed.json')
        owners[leaf] = owner(unit, start['invocation'])
        assert closed['passed'] and closed['pins_unchanged'] and closed['errors'] == []
        assert len(closed['rows']) == count
        pins.update(start['pins'])
        pins[str(root / 'started.json')] = sha(root / 'started.json')
        pins[str(root / 'closed.json')] = sha(root / 'closed.json')
        if count == 88:
            pins.update(closed['artifacts'])
        else:
            assert all(closed['memory_events'][key] == '0' for key in ('oom', 'oom_kill', 'oom_group_kill'))
        for row in closed['rows']:
            if count == 88:
                native = load(root / (row['name'] + '.native.json'))
                assert native['exit'] == row['native_exit'] == 133 and native['observed']
                assert all(value['exe'] == 'tb_ventium' and value['affinity'] == [12, 13]
                           for value in native['observed'].values())
                actual = root / (row['name'] + '.vtrace')
                golden = OLD / 'smsw-golden-r2' / actual.name
                log = (root / (row['name'] + '.log')).read_text()
                label = 'initial'
            else:
                out = root / (row['corpus'] + '-' + row['case'])
                fixture = OLD / row['corpus'] / row['case']
                native = load(out / 'native-closed.json')
                command = load(out / 'command.json')
                observed = native['observed']
                assert row['passed'] and row['native_exit'] == row['compare_exit'] + 133 == 133
                assert native['native_exit'] == 133 and native['actual_wait'] and native['process_absent']
                assert observed and observed['exe'] == str(model) and observed['argv'] == command['argv']
                assert observed['affinity'] == [command['cpu']] and command['cpu'] in (12, 13)
                assert observed['cgroup'].endswith('/' + unit + '\n')
                assert not (Path('/proc') / str(observed['pid'])).exists()
                assert observed in native['admission_samples']
                pins.update(row['artifacts'])
                pins[str(out / 'closed.json')] = sha(out / 'closed.json')
                assert sha(out / 'candidate.vtrace') == row['artifacts'][str(out / 'candidate.vtrace')]
                assert sha(fixture / 'probe.bin') == start['pins'][str(fixture / 'probe.bin')]
                actual, golden = out / 'candidate.vtrace', fixture / 'golden.vtrace'
                log = (out / 'native.log').read_text()
                label = row['corpus']
            compare(golden, actual)
            pair = re.findall(r'retires\s+(\d+)\s+\(U=(\d+)\s+pairedV=(\d+)\)', log)
            assert len(pair) == 1 and int(pair[0][0]) == int(pair[0][1]) + int(pair[0][2]) == row['records']
            acks = re.findall(r'\[L1DPERF\] fill cycles=\d+ backing-wait=\d+ backing-ack=(\d+)', log)
            assert len(acks) == 1 and int(acks[0]) > 0
            v_retirements += int(pair[0][2])
            backing_acks += int(acks[0])
            compare_count += 1
            records += row['records']
            counts[label] = counts.get(label, 0) + 1
    assert counts == {'initial': 88, 'smsw-privilege-r2': 60, 'smsw-retry-l0-r1': 25,
                      'smsw-retry-l7-r1': 25, 'smsw-retry-l31-r1': 25}
    assert compare_count == 223 and records == 29491 and v_retirements > 0
    assert all(sha(path) == expected for path, expected in pins.items())
    result = dict(audit_passed=True, model=sha(model), owners=owners, cases=counts,
        comparisons=compare_count, complete_architectural_records=records, paired_v_retirements=v_retirements,
        backing_acks=backing_acks, input_pins_checked=len(pins), pins=pins,
        no_custom_masks=True, no_compilation=True, standard_suite=False, hardware_acceptance=False,
        gameplay_ipc=None, known_qemu_lock_segment_disagreements_not_in_this_matrix=True)
    with (ROOT / 'fp-compare-smsw-audit.json').open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps({key: value for key, value in result.items() if key != 'pins'}), flush=True)


if __name__ == '__main__':
    main()
