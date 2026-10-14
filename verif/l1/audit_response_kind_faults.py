"""Regrade unchanged fault/boundary traces; preserve failed reference cases.

No simulator runs, field masks, fixture edits or acceptance promotion. The
first env-fault attempt's reference startup timeout remains failed evidence.
"""
import hashlib
import importlib.util
import io
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import compare
import tracefmt
import check_faultlog

spec = importlib.util.spec_from_file_location('native', REPO/'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def owner(unit, invocation, code):
    actual = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', unit, '-pMainPID', '-pSubState',
        '-pExecMainStatus', '-pInvocationID'], text=True).splitlines())
    assert actual == dict(MainPID='0', SubState='failed' if code else 'exited',
                         ExecMainStatus=str(code), InvocationID=invocation)
    return actual


def equivalent(golden, actual):
    output = io.StringIO()
    assert compare.compare_func(golden, actual, False, 0xffffffff, False, 20,
                                output, sys_both=True) == 0, output.getvalue()


def main():
    assert __debug__
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    root = scratch/'ventium-data-size.v2HaTO2X'
    pins = {str(p): sha(p) for p in (Path(__file__), Path(compare.__file__),
        Path(tracefmt.__file__), Path(check_faultlog.__file__), Path(native.__file__))}
    owners = []

    def pin_run(folder):
        started, closed = load(folder/'started.json'), load(folder/'closed.json')
        assert closed['pins_unchanged']
        pins.update(started['pins'])
        for name, digest in closed.get('artifacts', {}).items():
            assert sha(folder/name) == digest
        for path in folder.rglob('*'):
            if path.is_file():
                pins[str(path)] = sha(path)
        return started, closed

    expected = [dict(FULL=f, ENV16=w, HEAD=h, PRESENT=p, INJECT=0)
                for f, w, h, p in itertools.product((0, 1), (0, 1), range(5), (0, 1))]
    expected += [dict(FULL=f, ENV16=w, HEAD=4, PRESENT=1, INJECT=1)
                 for f, w in itertools.product((0, 1), (0, 1))]
    expected_keys = {tuple(sorted(c.items())) for c in expected}
    fault = root/'response-kind-env-fault-r2'
    started, closed = pin_run(fault)
    assert closed['passed'] and not closed['errors']
    assert all(closed['memory_events'][k] == '0' for k in ('oom', 'oom_kill', 'oom_group_kill'))
    owners.append(owner('ventium-response-kind-env-fault-oct14-r2.service', started['invocation'], 0))
    assert sha(started['model']) == 'da6744ec11615ca7900a6ed132bc9e64471dd567e363d33985864e50719be6dd'
    assert sha(started['qemu']) == 'f09369f734347c6ca0baf73b3edac8218c482b2fc1cd33c31b3e6672b7e51202'
    assert len(closed['rows']) == 44
    assert {tuple(sorted(r['case'].items())) for r in closed['rows']} == expected_keys
    count = records = pairs = 0
    for row in closed['rows']:
        case = row['case']
        folder = fault/('-'.join(k.lower()+str(v) for k, v in case.items()))
        assert sha(folder/'fixture.bin') == row['image_sha256']
        assert sha(folder/'fixture.bin') == sha(root/'prefix-payload-env-fault-r1'/folder.name/'fixture.bin')
        expected_exit = 135 if case['INJECT'] else 133
        assert row['passed'] and row['qemu_exit'] == expected_exit and row['golden_exit'] == 0
        assert [r['latency'] for r in row['rows']] == [0, 7]
        symbols = {r[2]: int(r[0], 16) for line in subprocess.check_output([
            'nm', '-n', folder/'fixture.elf'], text=True).splitlines()
            if len(r := line.split()) == 3 and r[0] != 'U'}
        for label, code in [('qemu', expected_exit), ('golden', 0),
                            ('rtl-l0', expected_exit), ('rtl-l7', expected_exit)]:
            receipt, argv = load(folder/(label+'.native.json')), load(folder/(label+'.command.json'))
            assert receipt['exit'] == code and receipt['child_reaped'] and receipt['observed_affinity']
            cpu = int(argv[2])
            assert 13 <= cpu <= 16 and all(v == [cpu] for v in receipt['observed_affinity'].values())
            assert str(folder/'fixture.bin') in argv
            if label.startswith('rtl'):
                assert started['model'] in argv and '--cycle-func' in argv and '--l1-axi' in argv
                assert not {'--dbg-step', '--dbg-bp', '--snapshot-in', '--no-trace'} & set(argv)
            else:
                assert started['qemu'] in argv and argv[argv.index('--cpu' if label == 'golden' else '-cpu')+1] == 'pentium'
        golden = tracefmt.read_trace(str(folder/'golden.vtrace'))
        for measurement in row['rows']:
            label = 'rtl-l'+str(measurement['latency'])
            text = (folder/(label+'.log')).read_text()+(folder/(label+'.stderr.log')).read_text()
            actual = tracefmt.read_trace(str(folder/(label+'.vtrace')))
            faults = re.findall(r'^\[FAULT\] vec=(\d+) err=([0-9a-f]+) pc=([0-9a-f]+)', text, re.M)
            wanted = [('14', f'{2+case["PRESENT"]:08x}', f'{symbols["hot_op"]:08x}')] if case['HEAD'] else []
            assert faults == wanted and actual.sys and not actual.x87
            assert not native.FATAL.search(text) and 100 < len(actual.records) < 4000
            assert int(actual.records[-1]['eax'], 16) & 255 == (0x43 if case['INJECT'] else 0x42)
            equivalent(golden, actual)
            paired = int(re.search(r'pairedV=(\d+)', text)[1])
            acks = re.findall(r'\[L1DPERF\] fill cycles=\d+ backing-wait=\d+ backing-ack=(\d+)', text)
            assert len(acks) == 1 and int(acks[0]) == measurement['backing_acks'] > 0
            assert paired == measurement['paired_v'] > 0
            assert measurement['rtl_self_check'] and measurement['compare_exit'] == 0
            assert len(actual.records) == measurement['records']
            records += len(actual.records); pairs += paired; count += 1
    assert count == 88

    first = root/'response-kind-env-fault-r1'
    old_start, old_closed = pin_run(first)
    owners.append(owner('ventium-response-kind-env-fault-oct14-r1.service', old_start['invocation'], 1))
    assert not old_closed['passed'] and not old_closed['errors'] and len(old_closed['rows']) == 44
    bad = [r for r in old_closed['rows'] if not r['passed']]
    assert len(bad) == 1 and bad[0]['golden_exit'] == 1
    assert bad[0]['case'] == dict(FULL=0, ENV16=0, HEAD=1, PRESENT=0, INJECT=0)
    assert all(m['rtl_self_check'] for r in old_closed['rows'] for m in r['rows'])
    for case in expected:
        name = '-'.join(k.lower()+str(v) for k, v in case.items())
        assert sha(first/name/'fixture.bin') == sha(fault/name/'fixture.bin')
    assert old_start['pins'] == started['pins'], 'retry changed inputs'

    boundary = root/'response-kind-boundary-r1'
    begun, result = pin_run(boundary)
    owners.append(owner('ventium-response-kind-boundary-oct14-r1.service', begun['invocation'], 1))
    assert not result['passed'] and result['all_children_reaped'] and len(result['errors']) == 8
    assert sorted(r['case'] for r in result['errors']) == [[2, r, o] for r in (0, 1) for o in (4080, 4093, 4094, 4095)]
    comparisons = executions = boundary_records = boundary_pairs = 0
    assert len(begun['cases']) == 30
    for kind, reloc, offset in begun['cases']:
        folder = boundary/f'k{kind}-r{reloc}-o{offset}'
        assert sha(folder/'test.bin') == sha(root/'prefix-payload-boundary-r1'/folder.name/'test.bin')
        free = load(folder/'free-qemu.exit.json')['native_exit']
        if kind == 2:
            assert free == 135 and not list(folder.glob('candidate*.vtrace'))
            continue
        assert free == 133 and load(folder/'golden.exit.json')['native_exit'] == 0
        golden = tracefmt.read_trace(str(folder/'golden.vtrace'))
        for latency in (0, 7):
            parent = {}
            for model in ('control', 'candidate'):
                for mode in ('cycle-func', 'cycle'):
                    stem = f'{model}-lat{latency}-{mode}'
                    actual = tracefmt.read_trace(str(folder/(stem+'.vtrace')))
                    code = load(folder/(stem+'.exit.json'))['native_exit']
                    stdout, stderr = [(folder/(stem+s)).read_text() for s in ('.stdout', '.stderr')]
                    assert code == 133 and not native.FATAL.search(stdout+stderr)
                    check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()), {(14, 0): 1} if kind == 1 else {})
                    assert [r['pc'] for r in actual.records] == [r['pc'] for r in golden.records]
                    if mode == 'cycle-func':
                        native.grade_native(actual, stdout, stderr, code, 133, 2000)
                        equivalent(golden, actual); comparisons += 1
                        if model == 'candidate': boundary_records += len(actual.records)
                    else:
                        v = sum(bool(r.get('paired')) and r.get('pipe') == 'V' for r in actual.records)
                        assert v > 0
                        if model == 'candidate': boundary_pairs += v
                    if model == 'control': parent[mode] = actual.records
                    else: assert actual.records == parent[mode]
                    executions += 1
    assert comparisons == 88 and executions == 176 and boundary_pairs == 428
    assert all(sha(path) == digest for path, digest in pins.items())
    audit = dict(evidence_audit_passed=True, owners=owners, artifact_pins=pins,
        fault_full_comparisons=count, fault_records=records, fault_paired_v=pairs,
        first_fault_run_passed=False, first_fault_failure='reference startup timeout; root cause unproved',
        boundary_full_gate_passed=False, boundary_reference_failures=8,
        boundary_full_comparisons=comparisons, boundary_rtl_executions=executions,
        boundary_candidate_records=boundary_records, boundary_candidate_v=boundary_pairs,
        boundary_complete_state_and_cycle_equal=True, boundary_child_affinity_observed=False,
        standard_suite=False, physical_board=False, gameplay_ipc=None)
    with (root/'response-kind-fault-audit.json').open('x') as stream:
        json.dump(audit, stream, indent=2)
    print(json.dumps({k: v for k, v in audit.items() if k != 'artifact_pins'}))


if __name__ == '__main__':
    main()
