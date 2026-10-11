#!/usr/bin/env python3
"""Resume after the proven QEMU port collision, without rewriting failed receipts.

The complete AGI matrix is rerun by the original pinned driver with one worker.
This controller requires both the original collision evidence and the complete
replacement matrix, then runs the unchanged fault/canonical/A-B gates. A red
canonical gate remains red, even if all parent/candidate traces are identical.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

REPO = Path(__file__).resolve().parents[2]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def records(path):
    import sys
    sys.path.insert(0, str(REPO/'verif/diff'))
    import tracefmt
    return tracefmt.read_trace(str(path)).records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--parent', type=Path, required=True)
    args = parser.parse_args()
    root, parent = args.root.resolve(strict=True), args.parent.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    original = load(root/'checks/closed.json')
    assert original['pins_unchanged'] and not original['directed_passed']
    assert [r['label'] for r in original['owners'] if r['ExecMainStatus'] != '0'] == ['agi']
    # Both jobs selected the same ephemeral TCP port. The second failed to bind,
    # connected to the first job, and emitted that other fixture's full trace.
    a, b = [root/'agi-r1'/name for name in ('k0-r0-o1', 'k0-r0-o7')]
    commands = [load(p/'golden.command.json') for p in (a, b)]
    ports = [c[c.index('--port')+1] for c in commands]
    assert ports == ['51617', '51617']
    assert 'Address already in use' in (b/'golden.vtrace.qemu.stderr').read_text()
    assert 'ConnectionResetError' in (a/'golden.stderr').read_text()
    assert records(b/'golden.vtrace') == records(parent.parent/'agi-r1/k0-r0-o1/golden.vtrace')
    assert records(b/'control-lat0-cycle-func.vtrace') == records(parent.parent/'agi-r1/k0-r0-o7/control-lat0-cycle-func.vtrace')
    first = load(root/'agi-r1/started.json')
    repeat = load(root/'agi-r2/started.json')
    assert first['workers'] == 4 and repeat['workers'] == 1
    for key in ('offsets', 'kinds', 'models'):
        assert repeat[key] == first[key], key
    # The first command used the canonical mount path; the rerun used its
    # external/tmp symlink. Resolve path identities, never normalize hashes.
    assert {str(Path(p).resolve(strict=True)):h for p,h in repeat['pins'].items()} == {
        str(Path(p).resolve(strict=True)):h for p,h in first['pins'].items()}
    pins = {**load(root/'checks/started.json')['pins'], **repeat['pins']}
    for label, count in [('branch',640), ('held',24), ('memory',72), ('fp',72), ('agi',12)]:
        directory = root/(label+('-r2' if label == 'agi' else '-r1'))
        receipt = directory/('result.json' if label == 'held' else 'closed.json')
        done = load(receipt)
        assert done['passed'] and not done['errors']
        assert done['inputs_unchanged' if label == 'held' else 'pins_unchanged']
        assert len(done['cases' if label == 'held' else 'measurements']) == count*(2 if label == 'held' else 4)
        pins[str(receipt)] = sha(receipt)
    for p in (Path(__file__), root/'checks/closed.json', root/'agi-r1/closed.json',
              root/'agi-r1/started.json', root/'agi-r2/started.json',
              b/'golden.vtrace', b/'golden.vtrace.qemu.stderr', a/'golden.stderr',
              b/'control-lat0-cycle-func.vtrace', a/'golden.command.json', b/'golden.command.json',
              REPO/'verif/l1/run_fp_read_ack_faults.py',
              REPO/'verif/issue_uv/run_fp_nomem_verify.py',
              REPO/'verif/l1/run_canonical_same_input_ab.py'):
        pins[str(p)] = sha(p)
    assert all(sha(p) == h for p,h in pins.items())
    work = root/'checks-r2'
    work.mkdir()
    def save(name, value):
        with (work/name).open('x') as stream:
            json.dump(value, stream, indent=2)
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        proven_port_collision=ports, original_failure_retained=True,
        original_820_fixtures_retained=True, sequential_agi_rerun=True))
    result = dict(directed_passed=False, canonical_gate_passed=False, errors=[],
                  gameplay_ipc=None, standard_suite=False, hardware_acceptance=False)
    begin = time.monotonic()
    def run(name, command, limit, tmpdir=scratch):
        assert shutil.disk_usage(scratch).free > 4*1024**3
        save(name+'-command.json', list(map(str, command)))
        with (work/(name+'.log')).open('x') as log:
            child = subprocess.run(list(map(str, command)), cwd=REPO,
                env={**os.environ, 'TMPDIR':str(tmpdir)}, stdout=log,
                stderr=subprocess.STDOUT, timeout=limit)
        save(name+'-exit.json', dict(native_exit=child.returncode))
        return child.returncode
    core = root/'core-r1'
    try:
        rc = run('faults', [REPO/'tools/build_scope.sh', '--', '/usr/bin/python3', '-B',
            REPO/'verif/l1/run_fp_read_ack_faults.py', '--parent', parent,
            '--candidate', core, '--out', root/'faults-r1'], 660)
        assert rc == 0
        faults = load(root/'faults-r1/closed.json')
        assert faults['passed'] and faults['pins_unchanged'] and not faults['errors']
        result['directed_passed'] = True
        rc = run('verify', ['/usr/bin/python3', '-B', REPO/'verif/issue_uv/run_fp_nomem_verify.py',
            '--parent', parent, '--core', core], 720, core)
        gate = load(core/'verify-closed.json')
        assert gate['pins_unchanged'] and not gate['masks_or_goldens_or_bands_changed']
        assert len(gate['deltas']) == 20 and all(r['same_records'] for r in gate['deltas'])
        result.update(canonical_gate_passed=gate['canonical_gate_passed'],
            canonical_native_exit=gate['canonical_gate_native_exit'],
            all_20_cycle_streams_identical=True, verify_controller_exit=rc)
        assert run('canonical-ab', ['/usr/bin/python3', '-B',
            REPO/'verif/l1/run_canonical_same_input_ab.py', '--parent', parent,
            '--candidate', core, '--out', root/'canonical-same-input'], 180) == 0
        result['all_108_functional_streams_identical'] = True
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(p) == h for p,h in pins.items()),
                  seconds=time.monotonic()-begin)
    save('closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['directed_passed'] and result['canonical_gate_passed'] and result['pins_unchanged'] and not result['errors'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
