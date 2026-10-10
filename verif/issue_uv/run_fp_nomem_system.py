#!/usr/bin/env python3
"""Reuse the complete FP payload A/B corpus with an unchanged define profile.

Only the original driver's feature-delta admission is specialized. Every QEMU,
x87-field, paired-retirement, early-command, native-exit and cycle check remains.
The original driver and its retained earlier runs are not edited.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
OLD = '''    added = {'VEN_FP_PIPE_PAYLOAD_SELECT'}
    assert {'VEN_P54_PREFIX_EX_CHAIN','VEN_P54_PREFIX_EX_SYSTEM'} <= profiles['control']
    assert not added & profiles['control']
    assert profiles['candidate'] == profiles['control'] | added'''
NEW = '''    assert {'VEN_P54_PREFIX_EX_CHAIN','VEN_P54_PREFIX_EX_SYSTEM',
            'VEN_FP_PIPE_PAYLOAD_SELECT','VEN_FP_SHARED_DIRECT',
            'VEN_FP_SHARED_EARLY_CMD','VEN_FP_MEM_ADMIT'} <= profiles['control']
    assert profiles['candidate'] == profiles['control']'''


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for flag in ('control', 'candidate', 'out'):
        ap.add_argument('--'+flag, type=Path, required=True)
    args = ap.parse_args()
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    root.mkdir()
    source = HERE/'run-fp-payload-ab.py'
    text = source.read_text()
    assert text.count(OLD) == 1 and text.count('HERE = Path(__file__).resolve().parent') == 1
    adapted = text.replace(OLD, NEW).replace('HERE = Path(__file__).resolve().parent', 'HERE = Path('+repr(str(HERE))+')')
    assert adapted.replace(NEW, OLD).replace('HERE = Path('+repr(str(HERE))+')',
        'HERE = Path(__file__).resolve().parent') == text
    runner = root/'run_same_profile_fp.py'
    with runner.open('x') as f:
        f.write(adapted)
    pins = {str(p): sha(p) for p in (Path(__file__), source, runner)}
    command = ['python3', '-B', str(runner), '--control', str(args.control.resolve(strict=True)),
        '--candidate', str(args.candidate.resolve(strict=True)), '--out', str(root/'matrix'), '--workers', '32']
    # Include both sides of a line seam and representative interior offsets.
    # All six FP/integer/memory patterns, flat and relocated paging, AXI 0/7.
    for offset in (0, 1, 7, 15, 30, 31):
        command += ['--offset', str(offset)]
    with (root/'started.json').open('x') as f:
        json.dump(dict(pins=pins, command=command, invocation=os.environ.get('INVOCATION_ID')), f, indent=2)
    with (root/'native.log').open('x') as f:
        result = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=600)
    unchanged = all(sha(Path(p)) == h for p, h in pins.items())
    with (root/'closed.json').open('x') as f:
        json.dump(dict(native_exit=result.returncode, pins_unchanged=unchanged,
            passed=result.returncode == 0 and unchanged, gameplay_ipc=None, standard_suite=False), f, indent=2)
    return 0 if result.returncode == 0 and unchanged else 1


if __name__ == '__main__':
    raise SystemExit(main())
