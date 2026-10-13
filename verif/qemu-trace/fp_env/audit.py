"""Read-only qualification audit for the private x87 environment reference.

Recheck real owner closure, matched helper-only linkage, immutable inputs,
native child affinity and every complete trace. This never promotes an oracle.
"""
import argparse
import hashlib
import io
import itertools
import json
from pathlib import Path
import subprocess
import sys

import prepare

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO/'verif/diff'))
import compare
import tracefmt


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def owner(unit, invocation, guarded=False):
    fields = ('MainPID', 'SubState', 'ExecMainStatus', 'Result', 'InvocationID',
              'ExecStart', 'ExecMainStartTimestampMonotonic',
              'ExecMainExitTimestampMonotonic', 'MemoryPeak')
    command = ['systemctl', '--user', 'show', unit]
    for field in fields:
        command += ['-p', field]
    result = dict(line.split('=', 1) for line in
                  subprocess.check_output(command, text=True).splitlines())
    assert result['MainPID']=='0' and result['SubState']=='exited'
    assert result['Result']=='success' and result['ExecMainStatus']=='0'
    if guarded:
        events = [json.loads(line) for line in subprocess.check_output([
            'journalctl', '--user', '--no-pager', '-o', 'json',
            'USER_INVOCATION_ID='+invocation], text=True).splitlines()]
        events = [e for e in events if e.get('USER_UNIT', '').startswith('ventium-build-')
                  and e.get('USER_UNIT', '').endswith('.scope')]
        launches = [e for e in events if e.get('JOB_TYPE')=='start']
        releases = [e for e in events if 'MEMORY_PEAK' in e]
        assert len(launches)==len(releases)==1 and launches[0]['JOB_RESULT']=='done'
        assert launches[0]['USER_UNIT']==releases[0]['USER_UNIT']
        assert 'build-r4' in launches[0]['MESSAGE'] and 'build-r4' in result['ExecStart']
        lo, hi = [int(result[key]) for key in
                  ('ExecMainStartTimestampMonotonic', 'ExecMainExitTimestampMonotonic')]
        assert lo <= int(launches[0]['__MONOTONIC_TIMESTAMP']) < int(releases[0]['__MONOTONIC_TIMESTAMP']) <= hi
        result['scope_invocation'] = invocation
        result['scope_unit'] = launches[0]['USER_UNIT']
        result['scope_memory_peak'] = releases[0]['MEMORY_PEAK']
        result['scope_swap_peak'] = releases[0].get('MEMORY_SWAP_PEAK')
    else:
        assert result['InvocationID']==invocation
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    args = ap.parse_args()
    assert __debug__
    root = args.root.resolve(strict=True)
    build, cases = root/'build-r4', root/'cases-r2'
    bs, bc = load(build/'started.json'), load(build/'closed.json')
    cs, cc = load(cases/'started.json'), load(cases/'closed.json')
    owners = {
        'build': owner('ventium-qemu-env-build-oct13-r4.service', bs['invocation'], True),
        'cases': owner('ventium-qemu-env-cases-oct13-r2.service', cs['invocation']),
    }
    for closure in (bc, cc):
        assert closure['passed'] and closure['pins_unchanged'] and not closure['errors']
        assert not closure['canonical_gate_passed'] and not closure['hardware_acceptance']
        assert closure['gameplay_ipc'] is None
    assert not cc['standard_suite']
    pins = {}
    for group in (bs['pins'], bc['pins'], cs['pins']):
        for path, digest in group.items():
            assert path not in pins or pins[path]==digest
            pins[path] = digest
    rows = {r['variant']:r for r in bc['rows']}
    assert set(rows)=={'control', 'candidate', 'wrong-v86-mode'}
    original = (build/'control/fpu_helper.c').read_text()
    assert sha(build/'control/fpu_helper.c')==prepare.SOURCE_SHA
    repaired = prepare.transform(original)
    assert repaired==(build/'candidate/fpu_helper.c').read_text()
    assert repaired.replace(' || (env->eflags & VM_MASK)', '')==(build/'wrong-v86-mode/fpu_helper.c').read_text()
    old_object = bs['compiler'][bs['compiler'].index('-o')+1]
    assert bs['linker'].count(old_object)==1
    for label, row in rows.items():
        folder = build/label
        assert sha(row['binary'])==row['sha256']
        assert sha(folder/'helper.o')==row['helper_sha256']
        assert sha(folder/'fpu_helper.c')==row['source_sha256']
        link = [str(folder/'helper.o') if token==old_object else token for token in bs['linker']]
        link[link.index('-o')+1] = str(folder/'qemu-system-i386')
        assert load(folder/'link-command.json')==link
        for stage in ('dependencies', 'compile', 'link'):
            assert load(folder/(stage+'-exit.json'))['native_exit']==0
        pins.update(row['artifacts'])
    witness = Path(cs['reused_closed_rtl'])
    wc = load(witness/'closed.json')
    assert len(wc['rows'])==192 and all(r['rtl_self_check'] for r in wc['rows'])
    expected = set(itertools.product((0,1,2), (0,1), (0,1), (0,1), (0,1), (0,1,63,4090)))
    keys = ('MODE', 'IN16', 'OUT16', 'FULL', 'SAVE', 'SHIFT')
    assert {tuple(c['defines'][k] for k in keys) for c in cs['cases']}==expected
    assert len(cs['cases'])==len(cc['rows'])==192
    by_case = {tuple(sorted(r['case'].items())):r for r in cc['rows']}
    total_records = mutant_failures = comparisons = affinity_receipts = 0
    for case in cs['cases']:
        folder, old = cases/case['name'], witness/case['name']
        row = by_case[tuple(sorted(case['defines'].items()))]
        pins.update(row['artifacts'])
        rtl = tracefmt.read_trace(str(old/'rtl.vtrace'))
        golden = tracefmt.read_trace(str(old/'golden.vtrace'))
        assert rtl.mode==golden.mode=='func' and rtl.sys and golden.sys
        assert rtl.x87==golden.x87==False  # Pointer memory readback is checked by guest code.
        total_records += len(rtl.records)
        for label in rows:
            observed = row['variants'][label]
            trace = tracefmt.read_trace(str(folder/(label+'.vtrace')))
            assert trace.mode=='func' and trace.sys and not trace.x87
            assert len(trace.records)==observed['records']
            for stage in ('native', 'trace'):
                native = load(folder/(label+'-'+stage+'-native.json'))
                command = load(folder/(label+'-'+stage+'-command.json'))
                assert command[:2]==['taskset', '-c']
                affinity = list(map(int, command[2].split(',')))
                assert affinity in ([8,9], [10,11], [12,13], [14,15])
                assert native['observed_affinity'] and all(v==affinity for v in native['observed_affinity'].values())
                assert native['exit']==observed['native_exit' if stage=='native' else 'trace_exit']
                affinity_receipts += 1
            assert observed['trace_exit']==0
            expected_native = 135 if label=='control' else 133
            bad_vm = label=='wrong-v86-mode' and case['defines']['MODE']==2 and not case['defines']['IN16'] and not case['defines']['OUT16']
            if bad_vm:
                expected_native = 135
                mutant_failures += 1
            assert observed['native_exit']==expected_native
            a, c = (golden, trace) if label=='control' else (trace, rtl)
            if label=='control':
                assert golden.records==trace.records
            got = compare.compare_func(a, c, False, tracefmt.EFLAGS_DEFAULT_MASK,
                                       False, 20, io.StringIO(), sys_both=True)
            assert got==observed['compare_exit']==int(bad_vm)
            command = load(folder/(label+'-compare-command.json'))
            assert len(command)==7 and command[3:5]==['--mode', 'func']
            assert Path(command[2]).resolve()==REPO/'verif/diff/compare.py'
            comparisons += 1
    assert total_records==26624 and mutant_failures==cc['mutant_detected']==16
    assert all(sha(path)==digest for path,digest in pins.items())
    print(json.dumps(dict(audit_passed=True, owners=owners, rehashed_pins=len(pins),
        private_reference_passes=192, unchanged_control_traces=192,
        wrong_v86_mode_detected=mutant_failures, comparisons=comparisons,
        native_affinity_receipts=affinity_receipts, candidate_records=total_records,
        closure_sha256={p.parent.name:sha(p) for p in (build/'closed.json', cases/'closed.json')},
        canonical_gate_passed=False, standard_suite=False,
        hardware_acceptance=False, gameplay_ipc=None), indent=2))


if __name__=='__main__':
    main()
