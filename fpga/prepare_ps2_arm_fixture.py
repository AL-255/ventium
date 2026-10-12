#!/usr/bin/env python3
"""Prepare a source-pinned ARM file-fixture package; never contact the board."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

FILES = ('ven_ps2_mmio.c', 'ven_ps2_mmio.py', 'test_ven_ps2_mmio.py',
         'ven_ps2_mouse.py', 'test_ven_ps2_mouse.py', 'ven_ps2_mailbox_host.py',
         'test_ven_ps2_mailbox_host.py', 'ven_ps2_service.py', 'test_ven_ps2_service.py')
SCRATCH_TESTS = ('test_ven_ps2_mmio.py', 'test_ven_ps2_service.py')


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def adapt_scratch(text):
    old = "self.assertEqual(scratch, Path('/home/yukidama/external/tmp').resolve(strict=True))"
    new = "self.assertEqual(scratch, Path(os.environ['VEN_PS2_TEST_ROOT']).resolve(strict=True))"
    if text.count(old) != 1 or new in text:
        raise ValueError('missing, duplicate or already-adapted scratch-root assertion')
    return text.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True,
                        help='closed run-ps2-mmio-gate.py export with all 61 software tests')
    parser.add_argument('--out', type=Path, required=True, help='fresh empty external directory')
    args = parser.parse_args()
    root, source = args.out.resolve(strict=True), args.source.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != Path('/').stat().st_dev
    assert root.parent == scratch and not list(root.iterdir())
    assert root.stat().st_uid == os.getuid() and len(os.sched_getaffinity(0)) == 1
    assert shutil.disk_usage(root).free > 4 * 1024**3
    closed = json.loads((source/'closed.json').read_text())
    started = json.loads((source/'started.json').read_text())
    assert closed['passed'] and closed['pins_unchanged']
    assert all(sha(Path(p)) == h for p,h in started['pins'].items())
    unit = (source/'unit.log').read_text()
    assert 'Ran 61 tests' in unit and unit.endswith('\nOK\n')
    pins = {str(source/n):sha(source/n) for n in (*FILES, 'started.json', 'closed.json', 'unit.log')}
    pins[str(Path(__file__).resolve())] = sha(Path(__file__))
    for name in FILES:
        text = (source/name).read_text()
        if name in SCRATCH_TESTS:
            text = adapt_scratch(text)
        with (root/name).open('x') as stream:
            stream.write(text)
    runner = Path(__file__).resolve().parent/'board-tools/check_ps2_arm_fixture.py'
    pins[str(runner)] = sha(runner)
    shutil.copyfile(runner, root/runner.name)
    compiler = Path(shutil.which('aarch64-linux-gnu-gcc')).resolve(strict=True)
    pins[str(compiler)] = sha(compiler)
    command = [str(compiler), '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-fPIC',
               '-shared', '-DVEN_PS2_MMIO_TEST', str(root/'ven_ps2_mmio.c'), '-o', str(root/'fixture.so')]
    with (root/'compile.log').open('xb') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
    production = source/'libven_ps2_mmio.so'
    assert sha(production) == closed['artifacts']['libven_ps2_mmio.so']
    pins[str(production)] = sha(production)
    shutil.copyfile(production, root/production.name)
    files = {name:sha(root/name) for name in (*FILES, runner.name, 'fixture.so', production.name)}
    assert all(sha(Path(p)) == h for p,h in pins.items())
    manifest = dict(files=files, source_pins=pins, compiler_command=command,
                    test_deltas=['explicit board scratch root only in two fixture setUp methods'],
                    production_source_changed=False, physical_mmio_tested=False)
    with (root/'manifest.json').open('x') as stream:
        json.dump(manifest, stream, indent=2)
    print(json.dumps(dict(files=len(files), manifest_sha256=sha(root/'manifest.json'), compile_exit=0)))


if __name__ == '__main__':
    main()
