#!/usr/bin/env python3
"""Small file-backed C tests and AArch64 build audit, not physical MMIO proof."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = args.out.resolve(strict=True)
    repo = Path(__file__).resolve().parent/'board-tools'
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.parent == scratch and not list(root.iterdir())
    assert shutil.disk_usage(root).free > 4 * 1024**3
    assert len(os.sched_getaffinity(0)) == 1 and os.environ['INVOCATION_ID']
    paths = [repo/n for n in ('ven_ps2_mmio.c', 'ven_ps2_mmio.py', 'test_ven_ps2_mmio.py')]
    tools = {n: Path(shutil.which(n)).resolve(strict=True) for n in
             ('gcc', 'aarch64-linux-gnu-gcc', 'aarch64-linux-gnu-objdump', 'aarch64-linux-gnu-nm', 'python3')}
    pins = {str(p):sha(p) for p in [*paths, *tools.values(), Path(__file__).resolve()]}
    for path in paths:
        shutil.copyfile(path, root/path.name)
        pins[str(root/path.name)] = sha(root/path.name)
    rows = []
    (root/'started.json').write_text(json.dumps(dict(pins=pins,
        invocation=os.environ['INVOCATION_ID'], affinity=sorted(os.sched_getaffinity(0))), indent=2))

    def run(label, argv, expected=0):
        start = time.monotonic()
        with (root/(label+'.log')).open('xb') as log:
            proc = subprocess.run(argv, cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=30)
        rows.append(dict(label=label, argv=argv, exit=proc.returncode, seconds=time.monotonic()-start))
        assert proc.returncode == expected, rows[-1]
        return (root/(label+'.log')).read_text()

    failure = None
    try:
        flags = ['-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-fPIC', '-shared']
        run('fixture-compile', [str(tools['gcc']), *flags, '-DVEN_PS2_MMIO_TEST', 'ven_ps2_mmio.c', '-o', 'fixture.so'])
        # A ctypes library must not share the Python module's import basename.
        run('arm64-compile', [str(tools['aarch64-linux-gnu-gcc']), *flags, 'ven_ps2_mmio.c', '-o', 'libven_ps2_mmio.so'])
        os.environ['VEN_PS2_MMIO_TEST_LIB'] = str(root/'fixture.so')
        unit = run('unit', [str(tools['python3']), '-B', '-m', 'unittest', '-v', 'test_ven_ps2_mmio'])
        assert 'Ran 13 tests' in unit and unit.endswith('\nOK\n')
        symbols = run('arm64-symbols', [str(tools['aarch64-linux-gnu-nm']), '-D', 'libven_ps2_mmio.so'])
        assert 'ven_ps2_mmio_open_fixture' not in symbols
        disassembly = run('arm64-disassembly', [str(tools['aarch64-linux-gnu-objdump']), '-d', 'libven_ps2_mmio.so'])
        assert 'dsb\tsy' in disassembly
        negative = run('x86-production-rejected', [str(tools['gcc']), *flags, 'ven_ps2_mmio.c', '-o', 'forbidden.so'], expected=1)
        assert 'Physical PS/2 MMIO backend requires AArch64' in negative
        assert not (root/'forbidden.so').exists()
    except Exception as error:
        failure = repr(error)
    stable = all(sha(Path(p)) == h for p,h in pins.items())
    result = dict(passed=failure is None and stable, error=failure, rows=rows,
        pins_unchanged=stable, artifacts={n:sha(root/n) for n in ('fixture.so', 'libven_ps2_mmio.so') if (root/n).exists()},
        physical_mmio_tested=False, arm64_ordering_runtime_tested=False, hardware_acceptance=False)
    (root/'closed.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
