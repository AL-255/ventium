#!/usr/bin/env python3
"""Reopen complete bus-cancellation regressions before exporting their RTL.

Local evidence only: no inherited full-suite, canonical or hardware pass.
"""
import argparse
import io
import json
from pathlib import Path
import subprocess
import sys

from build_bus_cancel_core import PAYLOAD, PARENT_MODEL, candidate_files, sha, load, stable
from prepare_bus_cancel_payload import transform
from run_bus_cancel_system import witness, fetch_fault_witness
from run_bus_cancel_smm import check_save, check_trace

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/diff'))
import compare
import tracefmt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'parent'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    root, parent = args.root.resolve(strict=True), args.parent.resolve(strict=True)
    core = root/'core-r1'
    started, built = load(core/'build-started.json'), load(core/'build-closed.json')
    assert __debug__ and built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    models = dict(control=parent/'obj/tb_ventium', candidate=core/'obj/tb_ventium')
    assert sha(models['control']) == started['parent_model'] == PARENT_MODEL
    assert sha(models['candidate']) == built['binary_sha256'] == 'f2797f8c17cb6c7d8668432ae69dd42d427d25a3e3d3b3cd1452de8d6582b4bf'
    files = [str(path.relative_to(core/'candidate')) for path in candidate_files(core/'candidate')]
    assert files == [str(path.relative_to(parent/'candidate')) for path in candidate_files(parent/'candidate')]
    assert len(files) == 195
    assert [name for name in files if sha(core/'candidate'/name) != sha(parent/'candidate'/name)] == [PAYLOAD]
    assert (core/'candidate'/PAYLOAD).read_text() == transform((parent/'candidate'/PAYLOAD).read_text())
    pins = dict(started['pins'])
    queue = load(root/'continuation-r1/closed.json')
    assert queue['sequence_finished'] and queue['directed_passed'] and queue['pins_unchanged'] and not queue['errors']
    assert queue['all_20_cycle_streams_identical'] and queue['all_108_functional_streams_identical']
    for owner in queue['owners']:
        observed = dict(line.split('=', 1) for line in subprocess.check_output([
            'systemctl', '--user', 'show', owner['unit'], '-pMainPID', '-pSubState',
            '-pInvocationID', '-pExecMainStatus'], text=True).splitlines())
        assert observed == {key: value for key, value in owner.items() if key != 'unit'}
        assert observed['MainPID'] == '0'
    expected = {'system-r2': (9, 31748), 'fp-r1/matrix': (72, 78048),
                'smm-r1': (2, 51160), 'rep-smi-r1': (1, 652)}
    summary = {}
    for relative, (count, records) in expected.items():
        folder = root/relative
        before, closed = load(folder/'started.json'), load(folder/'closed.json')
        assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
        pins.update(before['pins'])
        leaves = sorted({path.parent for path in folder.rglob('candidate-lat*-cycle-func.vtrace')})
        assert len(leaves) == count
        arch = cycle = paired = 0
        for leaf in leaves:
            golden_path = leaf/'golden.vtrace'
            golden = tracefmt.read_trace(str(golden_path)) if golden_path.exists() else None
            differential = relative == 'fp-r1/matrix' or (relative == 'system-r2' and leaf.name != 'pfetchlim')
            assert (golden is not None) == differential
            for latency in (0, 7):
                both = {}
                for name, model in models.items():
                    streams = {}
                    for mode in ('cycle-func', 'cycle'):
                        stem = f'{name}-lat{latency}-{mode}'
                        command = load(leaf/(stem+'.command.json'))
                        assert str(model) in command and '--'+mode in command and '--l1-axi' in command
                        assert load(leaf/(stem+'.exit.json'))['native_exit'] == 133
                        trace = tracefmt.read_trace(str(leaf/(stem+'.vtrace')))
                        assert trace.records and [row['n'] for row in trace.records] == list(range(len(trace.records)))
                        assert trace.mode == ('func' if mode == 'cycle-func' else 'cycle')
                        log = (leaf/(stem+'.stdout')).read_text()+(leaf/(stem+'.stderr')).read_text()
                        if mode == 'cycle-func':
                            arch += len(trace.records)
                            if golden is not None:
                                assert len(trace.records) == len(golden.records)
                                assert trace.sys and golden.sys and trace.x87 == golden.x87
                                assert compare.compare_func(golden, trace, golden.x87, 0xffffffff,
                                    False, 20, io.StringIO(), sys_both=True) == 0
                            if relative == 'system-r2':
                                witness(leaf.name, trace, log)
                            if relative == 'smm-r1':
                                check_trace(leaf.name, trace.records)
                            if relative == 'rep-smi-r1':
                                checked = leaf/(stem+'-boundary-check.exit.json')
                                assert load(checked)['native_exit'] == 0
                                check_command = load(leaf/(stem+'-boundary-check.command.json'))
                                assert str(REPO/'verif/sys/tests/prepsmi/prepsmi-rtl-selfcheck.py') in check_command
                                assert check_command[-3:] == ['0', '1', '1']
                        else:
                            cycle += len(trace.records)
                            if name == 'candidate':
                                paired += sum(row.get('pipe') == 'V' and row.get('paired') for row in trace.records)
                        if relative == 'system-r2' and leaf.name == 'pfetchlim':
                            fetch_fault_witness(log)
                        dump = leaf/(stem+'.smm.json')
                        if relative in ('smm-r1', 'rep-smi-r1'):
                            data = load(dump)
                            if leaf.name == 'psmm': check_save(data)
                            streams[mode+'-save-map'] = data
                        streams[mode] = trace.records
                    assert [row['pc'] for row in streams['cycle-func']] == [row['pc'] for row in streams['cycle']]
                    both[name] = streams
                assert both['control'] == both['candidate'], (relative, leaf.name, latency)
        assert arch == cycle == records, (relative, arch, cycle)
        summary[relative] = dict(fixtures=count, architectural_records=arch, cycle_records=cycle, candidate_v_retirements=paired)
        pins.update({str(path): sha(path) for path in folder.rglob('*') if path.is_file()})
    assert summary['system-r2']['candidate_v_retirements'] == 3068
    assert summary['fp-r1/matrix']['candidate_v_retirements'] > 0
    verify = load(core/'verify-closed.json')
    assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
    assert len(verify['deltas']) == 20 and all(row['same_records'] for row in verify['deltas'])
    for row in verify['deltas']:
        own, previous = core/'generic-work'/row['name'], parent/'generic-work'/row['name']
        assert tracefmt.read_trace(str(own)).records == tracefmt.read_trace(str(previous)).records
        for path in (own, previous): pins[str(path)] = sha(path)
    replay = root/'same-input-r1'
    before, done = load(replay/'started.json'), load(replay/'closed.json')
    assert done['same_input_regression_passed'] and done['pins_unchanged'] and not done['errors']
    assert len(before['cases']) == len(done['rows']) == 108 and done['records'] == 80800
    pins.update(before['pins'])
    total = 0
    for case in before['cases']:
        folder = replay/case['name']
        both = {}
        for name, model in models.items():
            command = load(folder/(name+'-command.json'))
            assert command[0] == str(model) and command[-2:] == ['--cycle-func', '--l1-axi']
            assert load(folder/(name+'-exit.json'))['native_exit'] == 0
            both[name] = tracefmt.read_trace(str(folder/(name+'.vtrace'))).records
        original = tracefmt.read_trace(case['original']).records
        assert both['control'] == both['candidate'] == original
        total += len(original)
    assert total == 80800
    for folder in (replay, root/'continuation-r1'):
        pins.update({str(path): sha(path) for path in folder.rglob('*') if path.is_file()})
    for path in (Path(__file__), core/'build-started.json', core/'build-closed.json',
                 core/'verify-started.json', core/'verify-closed.json',
                 root/'fp-r1/started.json', root/'fp-r1/closed.json'):
        pins[str(path)] = sha(path)
    pins.update(load(root/'fp-r1/started.json')['pins'])
    assert stable(pins)
    result = dict(audit_complete=True, directed_regressions_passed=True, model_sha256=built['binary_sha256'],
        source_deltas=[PAYLOAD], directed=summary, all_20_canonical_cycle_streams_identical=True,
        same_input_canonical_cases=108, same_input_canonical_records=total,
        canonical_gate_passed=verify['canonical_gate_passed'], standard_suite=False,
        hardware_acceptance=False, gameplay_ipc=None, timing_mhz=None, pins=pins)
    with (root/'core-audit.json').open('x') as stream: json.dump(result, stream, indent=2)
    print(json.dumps({key: value for key, value in result.items() if key != 'pins'}), flush=True)


if __name__ == '__main__': main()
