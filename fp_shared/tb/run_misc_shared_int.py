#!/usr/bin/env python3
"""Prepare/run an exact-parent, same-cycle serialized-converter sharing miter.

Preparation makes an isolated derivative of the three-file memory-C1 candidate.
Run under tools/build_scope.sh. Both notification-latency profiles must pass;
this is not architectural correctness, full-core or FPGA qualification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from prepare_misc_shared_int import transform


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def prepare(parent, out, repo):
    prior = json.loads((parent/'plan.json').read_text())
    assert all(sha(p) == h for p,h in prior['pins'].items())
    inputs = {
        'fpu_x87_pkg.sv': parent/'candidate/rtl/fpu/fpu_x87_pkg.sv',
        'ventium_decode_pkg.sv': parent/'candidate/rtl/core/ventium_decode_pkg.sv',
        'original.sv': parent/'candidate/fp_shared/ven_fp_misc.sv',
        'tb_misc_shared_int.sv': Path(__file__).with_name('tb_misc_shared_int.sv'),
    }
    original = inputs['original.sv'].read_text()
    assert original.count('module ven_fp_misc\n') == 1
    assert original.count('output      logic        rounded_up') == 1
    candidate = transform(original)
    out.mkdir()
    for name, source in inputs.items():
        shutil.copyfile(source, out/name)
    # Module renaming is the only reference change.
    (out/'reference.sv').write_text(original.replace('module ven_fp_misc\n',
                                                    'module ven_fp_misc_reference\n'))
    (out/'candidate.sv').write_text(candidate)
    evidence = [*inputs.values(), parent/'plan.json', Path(__file__),
                Path(__file__).with_name('prepare_misc_shared_int.py'),
                repo/'tools/build_scope.sh', repo/'tools/verilator_serial.sh',
                *out.iterdir()]
    pins = {str(p.resolve()):sha(p) for p in evidence}
    save(out/'prepared.json', dict(pins=pins, parent=str(parent),
        source_changes=['fp_shared/ven_fp_misc.sv'],
        reference_changes='module name only', profiles=['normal', 'early'],
        expected_cases_each=73728, architecture_qualified=False,
        parent_build_qualification='pending; preserves its behavior, not ISA proof',
        production_changed=False, gameplay_ipc=None))


def run(out, repo):
    assert os.environ.get('VENTIUM_BUILD_SCOPE_ACTIVE') == '1', 'use tools/build_scope.sh'
    plan = json.loads((out/'prepared.json').read_text())
    assert all(sha(p) == h for p,h in plan['pins'].items())
    assert not (out/'closed.json').exists()
    sources = [out/p for p in ('fpu_x87_pkg.sv','ventium_decode_pkg.sv',
                              'reference.sv','candidate.sv','tb_misc_shared_int.sv')]
    results = []
    started = time.monotonic()
    error = None
    try:
        for profile in plan['profiles']:
            work = out/profile
            work.mkdir()
            command = [str(repo/'tools/verilator_serial.sh'), '--binary', '--timing',
                '--assert', '-sv', '-j', '1', '-Wall', '-Wno-fatal', '-Wno-UNUSED',
                '-Werror-IMPLICIT', '-Werror-PINMISSING', '-Werror-UNDRIVEN',
                '-Werror-MULTIDRIVEN', '-Werror-LATCH', '-Werror-UNOPTFLAT',
                '--top-module', 'tb_misc_shared_int', '--Mdir', str(work/'obj')]
            if profile == 'early': command += ['+define+VEN_FP_MISC_EARLY_DONE']
            command += [str(p) for p in sources]
            save(work/'started.json', dict(command=command, time=time.time()))
            with (work/'build.log').open('xb') as stream:
                build = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                                       pass_fds=(9,), timeout=240)
            result = dict(profile=profile, build_native_exit=build.returncode, passed=False)
            results.append(result)
            if build.returncode: continue
            binary = work/'obj/Vtb_misc_shared_int'
            result['model_sha256'] = sha(binary)
            with (work/'run.log').open('xb') as stream:
                native = subprocess.run([str(binary)], stdout=stream, stderr=subprocess.STDOUT,
                                        pass_fds=(9,), timeout=30)
            result['run_native_exit'] = native.returncode
            result['passed'] = native.returncode == 0 and \
                'MISC-SHARED-INT-MITER-OK cases=73728 ' in (work/'run.log').read_text()
    except Exception as exc:
        error = repr(exc)
    stable = all(sha(p) == h for p,h in plan['pins'].items())
    result = dict(results=results, error=error, pins_unchanged=stable,
        passed=error is None and stable and len(results)==2 and all(r['passed'] for r in results),
        seconds=time.monotonic()-started, architecture_qualified=False,
        whole_core_test=False, fpga_qualified=False, production_changed=False, gameplay_ipc=None)
    save(out/'closed.json', result)
    print(json.dumps(result))
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--prepare-from', type=Path)
    args = parser.parse_args()
    assert __debug__, 'assertions required'
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert scratch.stat().st_dev != repo.stat().st_dev
    assert Path(os.environ['TMPDIR']).resolve(strict=True).is_relative_to(scratch)
    out = args.out.resolve()
    assert out.is_relative_to(scratch) and out != scratch
    assert shutil.disk_usage(scratch).free > 1024**3
    if args.prepare_from:
        assert not out.exists()
        prepare(args.prepare_from.resolve(strict=True), out, repo)
        print('Prepared private one-file derivative; no compiler or guest started.')
        return 0
    return run(out, repo)


if __name__ == '__main__':
    raise SystemExit(main())
