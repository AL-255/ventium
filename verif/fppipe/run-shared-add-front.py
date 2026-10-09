#!/usr/bin/env python3
"""Reproduce the isolated single-adder proposal; never modify production RTL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]
SCRATCH = Path('/home/yukidama/external/tmp')
CLASSES = ('IMPLICIT', 'PINMISSING', 'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, help='fresh directory on external scratch')
    parser.add_argument('--verilator', default='/tools/verilator/v5.046/bin/verilator')
    parser.add_argument('--auto-dsp', action='store_true',
                        help='also remove the module-wide force-DSP attribute')
    args = parser.parse_args()
    scratch = SCRATCH.resolve(strict=True)
    if scratch.stat().st_dev == REPO.stat().st_dev or shutil.disk_usage(scratch).free < 2*1024**3:
        parser.error('external filesystem with at least 2 GiB free is required')
    if args.out:
        out = args.out.resolve()
        if not out.is_relative_to(scratch):
            parser.error('--out must be below external/tmp')
        out.mkdir(parents=False, exist_ok=False)
    else:
        out = Path(tempfile.mkdtemp(prefix='ventium-shared-add-front-repro.', dir=scratch))
    patch = REPO/'verif/fppipe/shared-add-front.patch'
    patches = [patch]
    if args.auto_dsp:
        patches.append(REPO/'verif/fppipe/shared-add-auto-dsp.patch')
    original = REPO/'fp_shared/ven_fp_alu.sv'
    fixture = REPO/'verif/fppipe/tb_shared_add_front.sv'
    packages = [REPO/'rtl/fpu/fpu_x87_pkg.sv', REPO/'rtl/core/ventium_x87_pkg.sv']
    inputs = [original, *patches, fixture, *packages, Path(__file__), REPO/'tools/build_scope.sh']
    pins = {str(path): sha(path) for path in inputs}
    candidate = out/'candidate/fp_shared/ven_fp_alu.sv'
    candidate.parent.mkdir(parents=True)
    shutil.copyfile(original, candidate)
    # Applying the preserved diff only to this generated private copy makes
    # the exact proposal reproducible without editing the shared checkout.
    for proposal in patches:
        subprocess.run(['git', 'apply', '--check', str(proposal)], cwd=out/'candidate', check=True)
        subprocess.run(['git', 'apply', str(proposal)], cwd=out/'candidate', check=True)
    control = out/'ven_fp_alu_control.sv'
    text = original.read_text()
    assert text.count('module ven_fp_alu\n') == 1
    control.write_text(text.replace('module ven_fp_alu\n', 'module ven_fp_alu_control\n'))
    sources = [*packages, control, candidate, fixture]
    pins.update({str(path): sha(path) for path in (control, candidate)})
    env = dict(os.environ, TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1', CCACHE_DISABLE='1',
               VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32', VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32')
    argv = [str(REPO/'tools/build_scope.sh'), '--', 'timeout', '--signal=TERM',
            '--kill-after=15s', '600s', args.verilator, '--binary', '--timing', '--assert',
            '-j', '32', '-sv', '-Wall', '-Wno-fatal', '-Wno-UNUSED',
            *['-Werror-'+name for name in CLASSES], '--Mdir', str(out/'obj'),
            '--top-module', 'tb_shared_add_front', *map(str, sources)]
    (out/'started.json').write_text(json.dumps(dict(argv=argv, pins=pins, started=time.time()), indent=2)+'\n')
    result = dict(passed=False, tests=[], errors=[], gameplay_ipc=None, fpga_acceptance=False,
                  auto_dsp=args.auto_dsp)
    try:
        with (out/'build.log').open('x') as log:
            code = subprocess.run(argv, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
        result['build_exit'] = code
        assert code == 0, 'native build failed'
        binary = out/'obj/Vtb_shared_add_front'
        result['binary_sha256'] = sha(binary)
        for seed in (1, 17, 20260830):
            argv = ['timeout', '--signal=TERM', '--kill-after=5s', '60s', str(binary),
                    f'+verilator+seed+{seed}']
            with (out/f'seed-{seed}.log').open('x') as log:
                code = subprocess.run(argv, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
            text = (out/f'seed-{seed}.log').read_text()
            passed = code == 0 and text.count('SHARED-ADD-FRONT-AB-OK clocks=311557') == 1
            result['tests'].append(dict(seed=seed, native_exit=code, passed=passed))
            assert passed, f'seed {seed} failed'
        result['passed'] = True
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result['inputs_unchanged'] = all(sha(path) == digest for path, digest in pins.items())
        result['passed'] &= result['inputs_unchanged']
        result['finished'] = time.time()
        (out/'closed.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(dict(output=str(out), **result)), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
