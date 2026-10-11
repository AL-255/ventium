#!/usr/bin/env python3
"""Same full FP matrix; serialize QEMU port selection/start, keep 32 RTL workers.

The old select-free-port/close/start sequence can race another worker. Retain
that failed run and all original tests; change scheduling, not acceptance.
This lock coordinates this matrix's threads, not unrelated external programs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from run_fp_nomem_system import OLD, NEW

HERE = Path(__file__).resolve().parent
GOLDEN = '''        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        golden_path = leaf/'golden.vtrace'
        run(leaf, 'golden', [sys.executable, '-B', REPO/'verif/qemu-trace/gen_trace.py', '--qemu', qemu,
            '--system', '--x87', '--image', image, '--image-mode', 'bios', '--cpu', 'pentium',
            '--out', golden_path, '--max-insn', '2000', '--port', str(port)])
'''
SERIAL = '        with golden_lock:\n' + ''.join('    '+s+'\n' for s in GOLDEN.splitlines())


def adapt(text):
    replacements = (
        (OLD, NEW),
        ('HERE = Path(__file__).resolve().parent', 'HERE = Path('+repr(str(HERE))+')'),
        ('import traceback\n', 'import traceback\nimport threading\n'),
        ('    def check(case):\n', '    golden_lock = threading.Lock()\n\n    def check(case):\n'),
        (GOLDEN, SERIAL),
    )
    result = text
    for before, after in replacements:
        if result.count(before) != 1:
            raise ValueError('missing/ambiguous source anchor: '+before[:65])
        result = result.replace(before, after)
    original = result
    for before, after in reversed(replacements):
        original = original.replace(after, before)
    if original != text:
        raise ValueError('non-reversible scheduling adaptation')
    return result


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control', 'candidate', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    source = HERE/'run-fp-payload-ab.py'
    changed = adapt(source.read_text())
    root.mkdir()
    runner = root/'run_same_profile_fp_serial_golden.py'
    with runner.open('x') as f:
        f.write(changed)
    pins = {str(p): sha(p) for p in (Path(__file__), HERE/'run_fp_nomem_system.py', source, runner)}
    command = ['python3', '-B', str(runner), '--control', str(args.control.resolve(strict=True)),
        '--candidate', str(args.candidate.resolve(strict=True)), '--out', str(root/'matrix'), '--workers', '32']
    for offset in (0, 1, 7, 15, 30, 31):
        command += ['--offset', str(offset)]
    with (root/'started.json').open('x') as f:
        json.dump(dict(pins=pins, command=command, invocation=os.environ['INVOCATION_ID'],
                       sequential_goldens=True, rtl_workers=32), f, indent=2)
    with (root/'native.log').open('x') as f:
        done = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=600)
    stable = all(sha(Path(p)) == h for p,h in pins.items())
    with (root/'closed.json').open('x') as f:
        json.dump(dict(passed=done.returncode == 0 and stable, native_exit=done.returncode,
                       pins_unchanged=stable, gameplay_ipc=None, standard_suite=False), f, indent=2)
    return 0 if done.returncode == 0 and stable else 1


if __name__ == '__main__':
    raise SystemExit(main())
