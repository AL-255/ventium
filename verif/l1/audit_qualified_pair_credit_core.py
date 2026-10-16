"""Independently reconstruct the two-file core's closed system/gate evidence.

Parent equality is not a canonical pass. Preserve the canonical gate's native
verdict, including pre-existing failures; never award suite or FPGA acceptance.
"""
import argparse
import io
import json
from pathlib import Path
import subprocess

import build_qualified_pair_credit_core as build
import run_qualified_pair_credit_core as run

common = run.previous


def owner(unit, invocation, code):
    props = dict(s.split('=', 1) for s in subprocess.check_output(
        ['systemctl', '--user', 'show', unit, '-p', 'MainPID', '-p', 'InvocationID',
         '-p', 'Result', '-p', 'ExecMainStatus'], text=True, timeout=10).splitlines())
    assert props == dict(MainPID='0', InvocationID=invocation, ExecMainStatus=str(code),
                         Result='success' if code == 0 else 'exit-code'), props
    return props


def audit(root):
    core, parent = (root/n for n in ('qualified-pair-credit-core-r1', 'raw-prime-storage-core-r1'))
    system = root/'qualified-pair-credit-system-r1'
    start = json.loads((core/'build-started.json').read_text())
    built = json.loads((core/'build-closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert common.sha(core/'obj/tb_ventium') == built['binary_sha256'] == run.MODEL
    assert start['parent_model'] == common.sha(parent/'obj/tb_ventium') == run.PARENT
    assert start['changes'] == build.CHANGES
    assert start['definitions'] == json.loads((parent/'build-started.json').read_text())['definitions']
    assert len(start['definitions']) == 153
    names = [str(p.relative_to(core/'candidate')) for p in build.native.common.candidate_files(core/'candidate')]
    assert len(names) == 195
    assert sorted(n for n in names if common.sha(core/'candidate'/n) != common.sha(parent/'candidate'/n)) == build.CHANGES
    derived = run.recipe.transform({n:(parent/'candidate/rtl/mem'/n).read_text() for n in run.recipe.PINS})
    for name, text in derived.items():
        assert (core/'candidate/rtl/mem'/name).read_text() == text
    pins = dict(start['pins'])
    owners = dict(build=owner('ventium-qualified-pair-core-oct16-r1.service',
                             'e45d4f5570e845e4a740c0d8e61a3d35', 0))
    before, closed = [json.loads((system/n).read_text()) for n in ('started.json', 'closed.json')]
    owners['system'] = owner('ventium-qualified-pair-system-oct16-r1.service', before['invocation'], 0)
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert len(closed['rows']) == 180
    assert before['models'] == dict(parent=run.PARENT, candidate=run.MODEL)
    assert before['defines'] == start['definitions'] and before['no_step']
    assert all(closed['memory_events'][k] == '0' for k in ('oom', 'oom_kill', 'oom_group_kill'))
    pins.update(before['pins'])
    totals = dict(native_children=0, full_trace_pairs=0, candidate_records=0, candidate_v_retirements=0)
    for case in common.CASES:
        folder = system/case
        manifest = json.loads((common.REPO/'verif/sys/tests'/case/'manifest.json').read_text())
        gold = common.tracefmt.read_trace(str(folder/'gold.vtrace'))
        for latency in (0, 7, 31):
            for mode in ('cycle-func', 'cycle'):
                traces = {}
                for label, model in (('parent', parent), ('candidate', core)):
                    name = f'{label}-{latency}-{mode}'
                    receipt = json.loads((folder/(name+'.native.json')).read_text())
                    assert receipt['actual_wait'] and receipt['group_closed']
                    assert receipt['actual_return_code'] == manifest['exit_code']
                    for key in ('timed_out', 'cleanup_errors', 'descendant_leak', 'signals_after_reap'):
                        assert not receipt[key]
                    argv = receipt['argv']
                    assert all(flag in argv for flag in ('--'+mode, '--system', '--cosim', '--l1-axi',
                                                         f'AXI_RLAT={latency}', f'AXI_WLAT={latency}'))
                    assert receipt['native_affinity_observed'] and receipt['native_affinity'] == [int(argv[2])]
                    assert int(argv[2]) in run.CPUS
                    assert Path(receipt['native_executable']) == model/'obj/tb_ventium'
                    assert not Path('/proc', str(receipt['process_group'])).exists()
                    streams = []
                    for suffix in ('stdout', 'stderr'):
                        path = folder/(name+'.'+suffix)
                        assert common.sha(path) == receipt[suffix+'_sha256']
                        streams.append(path.read_text())
                    assert not common.native.FATAL.search(''.join(streams))
                    trace = common.tracefmt.read_trace(str(folder/(name+'.vtrace')))
                    traces[label] = trace.records
                    if mode == 'cycle-func':
                        common.native.grade_native(trace, *streams, manifest['exit_code'], manifest['exit_code'], manifest['max_insn'])
                        assert common.compare.compare_func(gold, trace, False, 0xffffffff, False, 20,
                                                           io.StringIO(), sys_both=True) == 0
                    if label == 'candidate':
                        totals['candidate_records'] += len(trace.records)
                        if mode == 'cycle':
                            totals['candidate_v_retirements'] += sum(r.get('pipe') == 'V' and r.get('paired', False) for r in trace.records)
                    totals['native_children'] += 1
                assert traces['parent'] == traces['candidate']
                totals['full_trace_pairs'] += 1
    assert totals['native_children'] == 180 and totals['full_trace_pairs'] == 90
    assert totals['candidate_v_retirements'] == closed['candidate_v_retirements'] > 0
    gate = json.loads((core/'verify-closed.json').read_text())
    gate_start = json.loads((core/'verify-started.json').read_text())
    assert gate['pins_unchanged'] and not gate['masks_or_goldens_or_bands_changed']
    assert gate['canonical_gate_passed'] == (gate['canonical_gate_native_exit'] == 0)
    assert gate['canonical_gate_native_exit'] in (0, 2)
    owners['canonical'] = owner('ventium-qualified-pair-verify-oct16-r1.service', gate_start['invocation'],
                                0 if gate['canonical_gate_passed'] else 1)
    cycle = sorted((core/'generic-work').glob('*.cycle_rtl.vtrace'))
    assert len(cycle) == 20
    for path in cycle:
        old = parent/'generic-work'/path.name
        assert common.tracefmt.read_trace(str(path)).records == common.tracefmt.read_trace(str(old)).records
        pins[str(old)] = common.sha(old)
        pins[str(path)] = common.sha(path)
    pins.update(gate_start['pins'])
    for path in (*system.rglob('*'), Path(__file__), Path(build.__file__), Path(run.__file__),
                 core/'build-started.json', core/'build-closed.json', core/'verify-started.json',
                 core/'verify-closed.json', core/'generic.log', core/'obj/tb_ventium'):
        if path.is_file():
            pins[str(path.resolve())] = common.sha(path)
    assert all(common.sha(p) == h for p, h in pins.items())
    return dict(directed_passed=True, models=dict(parent=run.PARENT, candidate=run.MODEL),
                source_changes=build.CHANGES, owners=owners, counts=totals, pins=pins,
                canonical_gate_passed=gate['canonical_gate_passed'],
                canonical_gate_native_exit=gate['canonical_gate_native_exit'],
                canonical_cycle_parent_identical=True, standard_suite=False,
                hardware_acceptance=False, gameplay_ipc=None, fmax_mhz=None)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    result = audit(root)
    common.save(root/'qualified-pair-credit-core-audit-r1.json', result)
    print(json.dumps({k:v for k,v in result.items() if k != 'pins'}, indent=2))
