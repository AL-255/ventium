"""Regrade closed finite-CS runs using the existing exception-delivery contract.

R1's host checker incorrectly forbade any trace record at the faulting PC.
core_int_deliver.svh intentionally emits one such record for completed delivery,
with handler CS and the pushed frame. Check that transition, not a trimmed trace.
Keep R1's failure and the original QEMU disagreement visible.
"""
import ast
import inspect
import json
import os
from pathlib import Path
import subprocess

import run_finite_cs_rtl as original

ORIGINAL_SHA = '4bc5f80fd3c751ea3893323d8f5faa5b2de7859af36675be432d832600984af5'
DELIVERY_SHA = 'e37ad609ee031351d8d7fdd0cd6fe836f8bcf84b39f72a8f4663a4f38d9b146b'


def check_delivery(trace, hot):
    positions = [i for i, r in enumerate(trace.records) if int(r['pc'], 16) == hot]
    assert len(positions) == 1 and 0 < positions[0] < len(trace.records)-1
    index = positions[0]
    before, delivery = trace.records[index-1:index+1]
    if trace.mode == 'func':
        assert int(before['cs'], 16) == 0x28 and int(delivery['cs'], 16) == 0x18
        assert int(before['eax'], 16) == int(delivery['eax'], 16) == 0x12348001
        assert int(before['ebx'], 16) == int(delivery['ebx'], 16) == 0x11112222
        assert int(before['esp'], 16) == 0x8fff0 and int(delivery['esp'], 16) == 0x8ffe0
        assert int(delivery['eflags'], 16) == int(before['eflags'], 16) & ~0x34300
        for key in original.tracefmt.func_compare_keys(False, True):
            if key not in ('pc', 'cs', 'esp', 'eflags'):
                assert delivery[key] == before[key], ('partial instruction commit', key)
    else:
        assert delivery['pipe'] == 'U' and not delivery['paired']
    return index


def check_witness_pairing(trace, pair_v):
    # Labels express the fixture author's intended pair, not mandatory slot
    # assignment. Here alignment's preceding NOP can pair with the first MOV,
    # leaving the second MOV to pair with the following MOV AL. Require actual
    # same-cycle U/V partners for BOTH register MOVs; do not accept U-only.
    for pc in (pair_v-5, pair_v):
        positions = [i for i, r in enumerate(trace.records) if int(r['pc'], 16) == pc]
        assert len(positions) == 1
        i = positions[0]; row = trace.records[i]
        if row['pipe'] == 'V':
            assert row['paired'] and i > 0
            u, v = trace.records[i-1:i+1]
        else:
            assert row['pipe'] == 'U' and i+1 < len(trace.records)
            u, v = trace.records[i:i+2]
        assert u['pipe'] == 'U' and v['pipe'] == 'V' and v['paired'] and u['cyc'] == v['cyc']


def checked_grade():
    assert original.sha(original.__file__) == ORIGINAL_SHA
    text = inspect.getsource(original.grade)
    bad = "assert all(int(r['pc'], 16) != hot for r in trace.records), 'faulting ADD retired'"
    assert text.count(bad) == 1
    text = text.replace(bad, 'check_delivery(trace, hot)')
    bad_pair = "assert any(int(r['pc'], 16) == pair_v for r in paired), 'ordinary witness did not pair'"
    assert text.count(bad_pair) == 1
    text = text.replace(bad_pair, 'check_witness_pairing(trace, pair_v)')
    ast.parse(text)
    namespace = dict(vars(original), check_delivery=check_delivery, check_witness_pairing=check_witness_pairing)
    exec(compile(text, __file__, 'exec'), namespace)
    return namespace['grade']


def main():
    assert __debug__
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    data = scratch/'ventium-data-size.v2HaTO2X'
    root = data/'response-kind-finite-cs-r1'
    begun, closed = [json.loads((root/n).read_text()) for n in ('started.json', 'closed.json')]
    owner = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', 'ventium-response-kind-finite-cs-oct14-r1.service',
        '-pMainPID', '-pSubState', '-pExecMainStatus', '-pInvocationID'], text=True).splitlines())
    assert owner == dict(MainPID='0', SubState='failed', ExecMainStatus='1', InvocationID=begun['invocation'])
    assert not closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert sorted(tuple(r['case']) for r in closed['rows']) == original.CASES
    pins = dict(begun['pins'])
    assert all(original.sha(p) == h for p, h in pins.items())
    assert all(original.sha(root/p) == h for p, h in closed['artifacts'].items())
    assert all(closed['memory_events'][k] == '0' for k in ('oom', 'oom_kill', 'oom_group_kill'))
    for leaf in ('prefix-payload-core-r1', 'response-kind-core-r1'):
        path = data/leaf/'candidate/rtl/core/core_int_deliver.svh'
        assert original.sha(path) == DELIVERY_SHA
        assert "q_pc          <= int_src_pc;" in path.read_text()
        assert "retire_valid  <= 1'b1;" in path.read_text()
    grade = checked_grade(); measurements = []; candidate_records = candidate_pairs = 0
    for case in sorted(closed['rows'], key=lambda r: r['case']):
        assert not case['passed'] and len(case['rows']) == 8 and len(case['errors']) == 12
        assert sum(e.get('error') == "AssertionError('faulting ADD retired')" for e in case['errors']) == 8
        assert sum(e.get('error') == 'not verified equal' for e in case['errors']) == 4
        _, reloc, offset = case['case']; folder = root/f'k2-r{reloc}-o{offset}'
        image = data/'response-kind-boundary-r1'/folder.name/'test.bin'
        symbols = {p[2]: int(p[0], 16) for line in subprocess.check_output([
            'nm', '-n', image.with_suffix('.elf')], text=True).splitlines()
            if len(p := line.split()) == 3 and p[0] != 'U'}
        assert symbols['pair_u'] == symbols['pair_v']-5
        traces, clocks = {}, {}
        for name in ('control', 'candidate'):
            for latency in (0, 7):
                for mode in ('cycle-func', 'cycle'):
                    stem = f'{name}-lat{latency}-{mode}'
                    receipt = json.loads((folder/(stem+'.native.json')).read_text())
                    argv = json.loads((folder/(stem+'.argv.json')).read_text())
                    assert receipt['native_exit'] == 133 and receipt['actual_wait'] and receipt['group_closed']
                    assert not receipt['timed_out'] and not receipt['leaked'] and not receipt['cleanup_errors']
                    assert not receipt['cleanup_signals'] and receipt['observed_affinity']
                    cpu = int(argv[2]); assert cpu in (13, 14, 15)
                    assert all(a == [cpu] for a in receipt['observed_affinity'].values())
                    assert begun['models'][name] in argv and str(image) in argv and '--l1-axi' in argv and '--'+mode in argv
                    trace = original.tracefmt.read_trace(str(folder/(stem+'.vtrace')))
                    row = grade(trace, (folder/(stem+'.stdout')).read_text(), (folder/(stem+'.stderr')).read_text(),
                                receipt['native_exit'], mode, symbols['hot_probe'], symbols['pair_v'])
                    index = check_delivery(trace, symbols['hot_probe'])
                    assert int(trace.records[index+1]['pc'], 16) == symbols['gp_handler']
                    traces[name, latency, mode] = trace.records; clocks[name, latency, mode] = row['clocks']
                    measurements.append(dict(case=case['case'], model=name, latency=latency, mode=mode, **row))
                    if name == 'candidate':
                        if mode == 'cycle-func': candidate_records += row['records']
                        else: candidate_pairs += row['paired_v']
        for latency in (0, 7):
            for mode in ('cycle-func', 'cycle'):
                assert traces['control', latency, mode] == traces['candidate', latency, mode]
            for name in ('control', 'candidate'):
                assert clocks[name, latency, 'cycle-func'] == clocks[name, latency, 'cycle']
                assert [r['pc'] for r in traces[name, latency, 'cycle-func']] == [r['pc'] for r in traces[name, latency, 'cycle']]
    assert len(measurements) == 64
    for p in (Path(__file__), Path(original.__file__), root/'closed.json', root/'started.json'):
        pins[str(p)] = original.sha(p)
    pins.update({str(root/p): h for p, h in closed['artifacts'].items()})
    result = dict(evidence_audit_passed=True, original_host_grade_passed=False,
        original_failure='checker incorrectly forbade the existing exception-delivery trace record',
        additional_checker_correction='both MOV witnesses paired, but not in the slots implied by their labels',
        original_boundary_qemu_gate_passed=False, reference_disagreement_waived=False,
        native_executions=64, candidate_functional_records=candidate_records,
        candidate_cycle_v_retirements=candidate_pairs, precise_gp_self_checks=True,
        complete_parent_state_and_cycles_equal=True, measurements=measurements, artifact_pins=pins,
        owner=owner, no_oom=True, differential=False, standard_suite=False,
        physical_board=False, gameplay_ipc=None)
    original.save(data/'response-kind-finite-cs-audit.json', result)
    print(json.dumps({k: v for k, v in result.items() if k not in ('artifact_pins', 'measurements')}, indent=2))


if __name__ == '__main__':
    main()
