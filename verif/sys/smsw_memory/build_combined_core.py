"""Compile the exact prepared SMSW + register-flag composition, when idle.

Reuse the source-pinned SMSW compiler/host-header checks without editing it.
No live Vivado may coexist. Preserve 32 compiler jobs with a lower 10/2 GiB
RAM/swap cap. Success qualifies compilation only, not a differential gate.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import traceback

import build_core as native
import compose_prime_reg as composition

NATIVE_SHA = '9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'


def validate(prepared):
    assert prepared['parent_model'] == composition.MODELS['flags']
    assert prepared['input_models'] == composition.MODELS
    assert prepared['exact_disjoint_composition'] and not prepared['compiler_started']
    assert prepared['changes'] == composition.SMSW_PATHS
    assert prepared['ancestor_changes'] == sorted([composition.FLAG_PATH]+composition.SMSW_PATHS)
    assert not prepared['canonical_gate_passed'] and not prepared['standard_suite']
    assert not prepared['hardware_acceptance'] and prepared['gameplay_ipc'] is None
    assert not prepared['parent_fault_differential_gate_passed']
    assert prepared['parent_intel_spec_only_cases'] == 20
    assert 'VL_J=32' in prepared['command']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    root = args.out.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root != scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != composition.REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    assert composition.sha(native.__file__) == NATIVE_SHA
    prepared = native.load(root/'prepared.json')
    validate(prepared)
    assert native.stable(prepared['pins'])
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    subprocess.run([native.REPO/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
    subprocess.run(['systemctl', '--user', 'set-property', '--runtime', 'ventium-ipc-parallel32.scope',
                    'MemoryMax=10G', 'MemorySwapMax=2G'], check=True, timeout=10)
    limits = dict(line.split('=', 1) for line in subprocess.check_output([
        'systemctl', '--user', 'show', 'ventium-ipc-parallel32.scope',
        '-p', 'MemoryMax', '-p', 'MemorySwapMax', '-p', 'InvocationID'], text=True).splitlines())
    assert limits['MemoryMax'] == str(10*1024**3) and limits['MemorySwapMax'] == str(2*1024**3)
    assert not (root/'build-started.json').exists()
    pins = {str(Path(p).resolve()): composition.sha(p) for p in (
        __file__, native.__file__, composition.__file__, root/'prepared.json',
        Path(__file__).with_name('test_build_combined_core.py'))}
    started = dict(pins=pins, scope=limits, controller_invocation=os.environ['INVOCATION_ID'],
                   utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False)
    native.save(root/'combined-build-started.json', started)
    result = dict(passed=False, errors=[], canonical_gate_passed=False, standard_suite=False,
                  hardware_acceptance=False, gameplay_ipc=None, fmax_mhz=None)
    try:
        # The original builder is unchanged; only its admitted parent identity
        # differs. Its exact source, definitions, command relocation, host/header
        # audit, resource scope, timeout and return-code checks remain active.
        assert native.MODEL == composition.MODELS['ancestor']
        assert native.CHANGES == composition.SMSW_PATHS
        native.MODEL = composition.MODELS['flags']
        code = native.build(root)
        result['driver_exit'] = code
        assert code == 0
        closed = native.load(root/'build-closed.json')
        assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
        result.update(passed=True, binary_sha256=closed['binary_sha256'], seconds=closed['seconds'])
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result['wrapper_pins_unchanged'] = native.stable(pins)
    result['passed'] &= result['wrapper_pins_unchanged']
    native.save(root/'combined-build-closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
