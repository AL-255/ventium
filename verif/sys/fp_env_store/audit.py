"""Read-only closure/source audit; directed passes never waive reference failures."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import prepare


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    args = ap.parse_args()
    root = args.root.resolve(strict=True)
    pins = {}
    receipts = []
    for folder, suffix, stem, expected in (
        ('store-leaf-r1', 'leaf', '', 0),
        ('store-core-r1', 'core', 'build-', 0),
        ('store-parent-r1', 'parent', '', 1),
        ('store-modes-r1', 'modes', '', 1),
        ('store-state-r1', 'state', '', 1),
        ('store-basic-r1', 'basic', '', 0),
        ('store-core-r1', 'verify', 'verify-', 1),
        ('store-replay-r2', 'replay', '', 0),
    ):
        run = root/folder
        started, closed = load(run/(stem+'started.json')), load(run/(stem+'closed.json'))
        unit = 'ventium-fp-env-store-'+suffix+'-oct13-'+('r2' if suffix=='replay' else 'r1')+'.service'
        owner = dict(line.split('=', 1) for line in subprocess.check_output([
            'systemctl', '--user', 'show', unit, '-p', 'MainPID', '-p', 'SubState',
            '-p', 'ExecMainStatus', '-p', 'InvocationID', '-p', 'ExecStart',
            '-p', 'ExecMainStartTimestampMonotonic', '-p', 'ExecMainExitTimestampMonotonic'], text=True).splitlines())
        assert owner['MainPID']=='0' and owner['SubState'] in ('exited','failed')
        assert int(owner['ExecMainStatus'])==expected
        if suffix in ('leaf','core'):
            # The guarded child records its own scope invocation, not the
            # outer service's. Join the real journal identity and time bounds.
            events = [json.loads(line) for line in subprocess.check_output([
                'journalctl', '--user', '--no-pager', '-o', 'json',
                'USER_INVOCATION_ID='+started['invocation']], text=True).splitlines()]
            events = [e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope']
            launches = [e for e in events if e.get('JOB_TYPE')=='start']
            releases = [e for e in events if 'MEMORY_PEAK' in e]
            assert len(launches)==len(releases)==1
            assert launches[0]['JOB_RESULT']=='done' and folder in launches[0]['MESSAGE']
            assert folder in owner['ExecStart']
            lo, hi = [int(owner[k]) for k in ('ExecMainStartTimestampMonotonic','ExecMainExitTimestampMonotonic')]
            assert lo <= int(launches[0]['__MONOTONIC_TIMESTAMP']) < int(releases[0]['__MONOTONIC_TIMESTAMP']) <= hi
            owner['scope_invocation']=started['invocation']
            owner['scope_memory_peak']=releases[0]['MEMORY_PEAK']
        else:
            assert owner['InvocationID']==started['invocation']
        assert closed['pins_unchanged'] and not closed.get('errors')
        pins.update(started['pins'])
        for row in closed.get('rows', []):
            pins.update(row.get('artifacts', {}))
        receipts.append(dict(folder=folder, unit=unit, owner=owner,
                             closure_sha256=sha(run/(stem+'closed.json'))))
    assert all(sha(path)==digest for path,digest in pins.items())
    parent, core = root/'core-r1', root/'store-core-r1'
    old, new = load(parent/'build-started.json'), load(core/'build-started.json')
    assert old['definitions']==new['definitions'] and len(new['definitions'])==152
    names = sorted(str(p.relative_to(parent/'candidate')) for p in (parent/'candidate').rglob('*') if p.is_file())
    assert len(names)==195
    assert names==sorted(str(p.relative_to(core/'candidate')) for p in (core/'candidate').rglob('*') if p.is_file())
    assert [n for n in names if sha(parent/'candidate'/n)!=sha(core/'candidate'/n)]==sorted(prepare.PARENTS)
    for n in prepare.PARENTS:
        assert prepare.transform((parent/'candidate'/n).read_text(), n)==(core/'candidate'/n).read_text()
    def by_case(folder):
        rows = load(root/folder/'closed.json')['rows']
        return {tuple(sorted(r['case'].items())):r for r in rows}
    before, after = by_case('store-parent-r1'), by_case('store-modes-r1')
    assert len(before)==len(after)==192 and before.keys()==after.keys()
    for key, row in after.items():
        control = before[key]
        assert row['rtl_self_check'] and not row['faults']
        assert control['rtl_self_check']==bool(row['case']['MODE']==0 or row['case']['OUT16'])
        assert not control['faults'] and not row['passed'] and row['qemu_exit']==135
        image_hashes = lambda r: [h for p,h in r['artifacts'].items() if p.endswith('/probe.bin')]
        assert len(image_hashes(row))==1 and image_hashes(row)==image_hashes(control)
    leaf = load(root/'store-leaf-r1/closed.json')
    assert leaf['passed'] and len(leaf['rows'])==2
    assert 'ENV-STORE32 mode=2 full=0 sample=0' in leaf['rows'][0]['log']
    assert 'FP-ENV-STORE-OK cases=1024 stores=4096' in leaf['rows'][1]['log']
    basic, state = [load(root/folder/'closed.json') for folder in ('store-basic-r1','store-state-r1')]
    assert basic['passed'] and len(basic['rows'])==32 and all(r['passed'] for r in basic['rows'])
    assert len(state['rows'])==24 and all(r['rtl_self_check'] and not r['passed'] for r in state['rows'])
    verify = load(core/'verify-closed.json')
    assert not verify['canonical_gate_passed'] and verify['canonical_gate_native_exit']==2
    assert len(verify['deltas'])==20 and all(r['same_records'] for r in verify['deltas'])
    replay = load(root/'store-replay-r2/closed.json')
    assert replay['same_input_regression_passed'] and len(replay['rows'])==108
    assert replay['records']==80800 and all(r['passed'] for r in replay['rows'])
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'diff'))
    import tracefmt
    artifacts = {}
    for case in load(root/'store-replay-r2/started.json')['cases']:
        folder = root/'store-replay-r2'/case['name']
        traces = [tracefmt.read_trace(str(p)) for p in
                  (folder/'control.vtrace', folder/'candidate.vtrace', Path(case['original']))]
        assert traces[0].records==traces[1].records==traces[2].records
        assert traces[0].mode==traces[1].mode==traces[2].mode=='func'
        assert traces[0].x87==traces[1].x87==traces[2].x87
        for label in ('control','candidate'):
            assert load(folder/(label+'-exit.json'))['native_exit']==0
            command = load(folder/(label+'-command.json'))
            assert '--cycle-func' in command and '--l1-axi' in command
        artifacts.update({str(p):sha(p) for p in folder.iterdir() if p.is_file()})
    assert all(sha(path)==digest for path,digest in pins.items())
    print(json.dumps(dict(audit_passed=True, receipts=receipts, rehashed_pins=len(pins),
        replay_artifacts=len(artifacts), replay_artifact_digest=hashlib.sha256(
            json.dumps(artifacts, sort_keys=True).encode()).hexdigest(),
        model_sha256=sha(core/'obj/tb_ventium'), source_count=195, changed=sorted(prepare.PARENTS),
        mode_self_checks=192, mode_reference_passes=0, canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None), indent=2))


if __name__ == '__main__':
    main()
