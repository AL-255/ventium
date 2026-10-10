#!/usr/bin/env python3
"""Reproduce the same-cycle estimator-width miter against the pinned prechange RTL.

Invoke inside tools/build_scope.sh; writes only a fresh external scratch tree.
This is a leaf equivalence test, not full-core or FPGA acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

BASE_REV = 'eaf2faaf'
BASE_SHA = '8b6260df1025996cbbbb4e819d66c2cadcd52f8fc8da4f4890bfdf3179bff69a'


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
    assert os.environ.get('VENTIUM_BUILD_SCOPE_ACTIVE') == '1', 'use tools/build_scope.sh'
    out = args.out.resolve()
    assert out.is_relative_to(scratch) and not out.exists()
    assert shutil.disk_usage(scratch).free > 1024**3
    base = subprocess.check_output(['git', 'show', BASE_REV+':fp_shared/ven_fp_estdiv.sv'], cwd=repo)
    assert hashlib.sha256(base).hexdigest() == BASE_SHA
    assert base.count(b'module ven_fp_estdiv (') == 1
    out.mkdir()
    (out/'original.sv').write_bytes(base.replace(b'module ven_fp_estdiv (', b'module ven_fp_estdiv_reference ('))
    sources = [out/'original.sv', repo/'fp_shared/ven_fp_estdiv.sv',
               Path(__file__).with_name('tb_estdiv_narrow.sv')]
    pins = {str(p):sha(p) for p in [Path(__file__), *sources,
            repo/'tools/build_scope.sh', repo/'tools/verilator_serial.sh']}
    cmd = [str(repo/'tools/verilator_serial.sh'), '--binary', '--timing', '--assert',
           '-sv', '-j', '1', '-Wall', '-Wno-fatal', '-Wno-UNUSED',
           '-Werror-IMPLICIT', '-Werror-PINMISSING', '-Werror-UNDRIVEN',
           '-Werror-MULTIDRIVEN', '-Werror-LATCH', '-Werror-UNOPTFLAT',
           '--top-module', 'tb_estdiv_narrow', '--Mdir', str(out/'build'), *map(str,sources)]
    (out/'inputs.json').write_text(json.dumps(dict(pins=pins, command=cmd,
        reference_revision=BASE_REV, reference_sha256=BASE_SHA), indent=2)+'\n')
    start = time.monotonic()
    with (out/'build.log').open('xb') as f:
        build = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, pass_fds=(9,), timeout=540)
    result = dict(passed=False, build_exit=build.returncode, whole_core_test=False)
    if not build.returncode:
        exe = out/'build/Vtb_estdiv_narrow'
        with (out/'run.log').open('xb') as f:
            run = subprocess.run([str(exe)], stdout=f, stderr=subprocess.STDOUT, pass_fds=(9,), timeout=30)
        result.update(run_exit=run.returncode, model_sha256=sha(exe))
        result['passed'] = run.returncode == 0 and 'ESTDIV-NARROW-MITER-OK' in (out/'run.log').read_text()
    result['pins_unchanged'] = all(sha(p)==h for p,h in pins.items())
    result['passed'] &= result['pins_unchanged']
    result['seconds'] = time.monotonic()-start
    (out/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
