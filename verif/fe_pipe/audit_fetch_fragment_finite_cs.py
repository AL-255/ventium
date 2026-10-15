"""Apply the existing exception-frame and dual-MOV pairing audit to this run."""
import json
import os
from pathlib import Path
import subprocess

import audit_finite_cs_rtl as contract
import prepare_fetch_fragment_extent as recipe
import run_fetch_fragment_finite_cs as run


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == Path('/home/yukidama/external/tmp').resolve()
    root = run.DATA/'fetch-fragment-finite-cs-r5'
    start, closed = [json.loads((root/name).read_text()) for name in ('started.json', 'closed.json')]
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert not closed['original_gate_passed'] and not closed['qemu_differential']
    assert all(closed['memory_events'][name] == 0 for name in ('oom', 'oom_kill', 'oom_group_kill'))
    owner = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', 'ventium-fetch-fragment-finite-cs-oct15-r5.service',
        '-pMainPID', '-pSubState', '-pExecMainStatus', '-pInvocationID'], text=True).splitlines())
    assert owner == dict(MainPID='0', SubState='exited', ExecMainStatus='0', InvocationID=start['invocation'])
    pins = dict(start['pins'])
    closures = {}
    for label, (name, digest) in run.MODELS.items():
        core = run.DATA/name
        built = json.loads((core/'build-started.json').read_text())
        closure = {str(Path(p).relative_to(core/'candidate')): h for p,h in built['pins'].items()
                   if Path(p).is_relative_to(core/'candidate')}
        assert len(closure) == 195 and run.sha(core/'obj/tb_ventium') == digest
        assert run.sha(core/'candidate/rtl/core/core_int_deliver.svh') == contract.DELIVERY_SHA
        closures[label] = closure
        pins.update({str(core/'candidate'/p): h for p,h in closure.items()})
    assert closures['parent'].keys() == closures['candidate'].keys()
    assert [p for p in closures['parent'] if closures['parent'][p] != closures['candidate'][p]] == [recipe.FILE]
    assert (run.DATA/'fetch-fragment-core-r1/candidate'/recipe.FILE).read_text() == recipe.transform(
        (run.DATA/'prefix-payload-core-r1/candidate'/recipe.FILE).read_text())
    assert all(run.sha(p) == h for p,h in pins.items())
    grade = contract.checked_grade()
    measurements, candidate_records, candidate_pairs = [], 0, 0
    assert [row['case'] for row in closed['rows']] == run.CASES
    for case in closed['rows']:
        leaf = root/case['case']
        image = run.DATA/'prefix-payload-boundary-r1'/case['case']/'test.bin'
        symbols = dict((p[2], int(p[0], 16)) for line in subprocess.check_output(
            ['nm', '-n', image.with_suffix('.elf')], text=True).splitlines()
            if len(p := line.split()) == 3 and p[0] != 'U')
        traces, counts = {}, {}
        assert len(case['rows']) == 12
        for row in case['rows']:
            label, latency, mode = row['model'], row['latency'], row['mode']
            assert label in run.MODELS and latency in (0, 7, 31) and mode in ('cycle-func', 'cycle')
            key = label, latency, mode
            assert key not in traces
            stem = f'{label}-lat{latency}-{mode}'
            receipt = json.loads((leaf/(stem+'.native.json')).read_text())
            assert receipt == row['native'] and receipt['native_exit'] == 133
            assert receipt['actual_wait'] and receipt['reaped']
            argv = receipt['command'][3:]
            assert receipt['observed']['argv'] == argv
            assert receipt['observed']['affinity'] == [int(receipt['command'][2])]
            assert argv[0] == start['models'][label] and argv[argv.index('--image')+1] == str(image)
            assert '--l1-axi' in argv and '--'+mode in argv
            assert not any('step' in arg or 'snapshot' in arg or 'dbg-bp' in arg for arg in argv)
            trace = run.tracefmt.read_trace(str(leaf/(stem+'.vtrace')))
            assert run.sha(leaf/(stem+'.vtrace')) == row['trace_sha256']
            measured = grade(trace, (leaf/(stem+'.stdout')).read_text(), (leaf/(stem+'.stderr')).read_text(),
                             receipt['native_exit'], mode, symbols['hot_probe'], symbols['pair_v'])
            index = contract.check_delivery(trace, symbols['hot_probe'])
            assert int(trace.records[index+1]['pc'], 16) == symbols['gp_handler']
            traces[key], counts[key] = trace.records, measured['clocks']
            measurements.append(dict(case=case['case'], model=label, latency=latency, mode=mode, **measured))
            if label == 'candidate':
                if mode == 'cycle-func': candidate_records += measured['records']
                else: candidate_pairs += measured['paired_v']
        for latency in (0, 7, 31):
            for mode in ('cycle-func', 'cycle'):
                assert traces['parent', latency, mode] == traces['candidate', latency, mode]
            for label in run.MODELS:
                assert counts[label, latency, 'cycle-func'] == counts[label, latency, 'cycle']
                assert [r['pc'] for r in traces[label, latency, 'cycle-func']] == [r['pc'] for r in traces[label, latency, 'cycle']]
    assert (len(measurements), candidate_records, candidate_pairs) == (96, 3048, 264)
    for path in (Path(__file__), Path(contract.__file__), Path(contract.original.__file__), Path(recipe.__file__)):
        pins[str(path.resolve())] = run.sha(path)
    pins.update({str(path): run.sha(path) for path in root.rglob('*') if path.is_file()})
    assert all(run.sha(p) == h for p,h in pins.items())
    result = dict(passed=True, native_executions=96, complete_parent_comparisons=48,
        candidate_functional_records=candidate_records, candidate_v_retirements=candidate_pairs,
        exception_delivery_state_checked=True, both_mov_witnesses_paired=True,
        source_closure_checked=True, owner=owner, measurements=measurements, pins=pins,
        original_qemu_gate_passed=False, differential=False, standard_suite=False,
        hardware_acceptance=False, gameplay_ipc=None)
    run.save(root/'audit.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins', 'measurements')}), flush=True)


if __name__ == '__main__': main()
