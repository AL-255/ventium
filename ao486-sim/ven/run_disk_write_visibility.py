#!/usr/bin/env python3
"""Build the real PS shim against a generated model header; no RTL execution.

The control must demonstrate stale live data; the candidate must make all
writes visible and detect delayed /dev/full errors. Sources are pinned, and
the output directory must be new and on the designated external scratch disk.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--control-shim', type=Path, required=True)
    ap.add_argument('--model-dir', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve(strict=True).is_relative_to(scratch)
    out = args.out.resolve()
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert shutil.disk_usage(scratch).free > 2 * 1024**3
    model = args.model_dir.resolve(strict=True)
    control = args.control_shim.resolve(strict=True)
    candidate = repo / 'ao486-sim/ps/ps_shim.cpp'
    fixture = Path(__file__).with_name('test_disk_write_visibility.cpp')
    verilator = Path('/tools/verilator/v5.046/share/verilator/include')
    assert sha(control) == '623dcb7e4290512d50d3a5c49cf665deb3c590e2b9d7f5d10b886bf29e0847ae'
    assert sha(candidate) != sha(control)
    paths = [Path(__file__), control, candidate, fixture, model / 'Vsystem.h']
    paths += list((repo / 'ao486-sim/ps').rglob('*.h'))
    paths += list(verilator.glob('*.h'))
    pins = {str(p.resolve()): sha(p) for p in paths}
    out.mkdir()
    compiler = '/usr/bin/g++'
    version = subprocess.check_output([compiler, '--version'], text=True)
    started = dict(pins=pins, compiler=compiler, compiler_version=version,
                   rtl_executed=False, guest_modified=False, gameplay_ipc=None)
    (out / 'started.json').write_text(json.dumps(started, indent=2))
    rows = []
    for name, source in (('control', control), ('candidate', candidate)):
        folder = out / name
        folder.mkdir()
        binary = folder / 'test'
        command = [compiler, '-std=c++17', '-O1', '-ffunction-sections', '-fdata-sections',
                   '-I' + str(model), '-I' + str(verilator), '-I' + str(verilator / 'vltstd'),
                   '-I' + str(repo / 'ao486-sim/ps'), str(source), str(fixture),
                   '-Wl,--gc-sections', '-o', str(binary)]
        start = time.monotonic()
        with (folder / 'build.log').open('x') as log:
            built = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=60)
        assert built.returncode == 0
        data = folder / 'data'
        data.mkdir()
        native = subprocess.run([str(binary), str(data)], capture_output=True, text=True, timeout=15)
        (folder / 'stdout').write_text(native.stdout)
        (folder / 'stderr').write_text(native.stderr)
        expected = ('WRITE-VISIBILITY cases=18 stale=18 post_close_errors=0 falsely_successful_errors=2\n'
                    if name == 'control' else
                    'WRITE-VISIBILITY cases=18 stale=0 post_close_errors=0 falsely_successful_errors=0\n')
        assert native.stdout == expected and not native.stderr
        assert native.returncode == (1 if name == 'control' else 0)
        rows.append(dict(name=name, build_command=command, build_exit=built.returncode,
                         native_exit=native.returncode, stdout=native.stdout,
                         binary_sha256=sha(binary), seconds=time.monotonic() - start))
    assert all(sha(p) == h for p, h in pins.items())
    result = dict(passed=True, rows=rows, pins_unchanged=True, valid_write_cases_each=18,
                  delayed_error_cases_each=2, rtl_changed=False, rtl_executed=False,
                  power_loss_durability_tested=False, standard_suite=False, gameplay_ipc=None)
    (out / 'closed.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
