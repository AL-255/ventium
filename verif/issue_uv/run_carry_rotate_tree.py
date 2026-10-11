#!/usr/bin/env python3
"""Bounded native A/B checks of the complete old/new shift helper packages.

Run in a retained service (one CPU, <=512 MiB, no swap). No Vivado or full-core
build is launched, and no active frozen source is changed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

from prepare_carry_rotate_tree import transform


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    source, out = args.parent.resolve(strict=True), args.out.resolve()
    here = Path(__file__).resolve().parent
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert shutil.disk_usage(scratch).free > 4*1024**3
    assert re.fullmatch('[0-9a-f]{32}', os.environ.get('INVOCATION_ID', ''))
    assert len(os.sched_getaffinity(0)) == 1, 'use actual taskset confinement'
    original = source.read_text()
    candidate = transform(original)
    assert original.count('package ventium_alu_pkg;') == 1
    assert original.count('endpackage : ventium_alu_pkg') == 1
    reference = original.replace('package ventium_alu_pkg;', 'package alu_reference;').replace(
        'endpackage : ventium_alu_pkg', 'endpackage : alu_reference')
    pins = {str(p): sha(p) for p in (source, Path(__file__).resolve(),
        here/'prepare_carry_rotate_tree.py', here/'test_carry_rotate_tree.py',
        here/'tb_carry_rotate_tree.sv', Path('/usr/bin/iverilog'), Path('/usr/bin/vvp'))}
    out.mkdir()
    for name, text in (('reference.sv', reference), ('ventium_alu_pkg.sv', candidate)):
        with (out/name).open('x') as stream:
            stream.write(text)
    shutil.copyfile(here/'tb_carry_rotate_tree.sv', out/'tb.sv')
    variants = [
        ('positive', candidate, 0),
        ('mask-count-mutant', candidate.replace("steps = cnt[5] ? 6'd32 : cnt;",
                                               "steps = {1'b0,cnt[4:0]};"), 1),
        ('wrong-carry-mutant', candidate.replace('shrot_cf = ring[32];',
                                                 'shrot_cf = ring[0];'), 1),
        ('wrong-narrow-ring-mutant', candidate.replace('(1 << stage) % 17',
                                                       '(1 << stage) % 16'), 1),
    ]
    for name, text, expected in variants:
        assert not expected or text != candidate
        with (out/(name+'.sv')).open('x') as stream:
            stream.write(text)
    pins.update({str(p): sha(p) for p in out.glob('*.sv')})
    save(out/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        parent=str(source), affinity=sorted(os.sched_getaffinity(0)),
        native_helpers=True, whole_core=False, timing_mhz=None, gameplay_ipc=None))
    rows, error = [], None
    begin = time.monotonic()
    try:
        for name, _, expected in variants:
            binary = out/(name+'.vvp')
            command = ['/usr/bin/iverilog', '-g2012', '-s', 'tb_carry_rotate_tree',
                '-DVEN_FAST_ROR_IMM', '-o', str(binary), str(out/'reference.sv'),
                str(out/(name+'.sv')), str(out/'tb.sv')]
            save(out/(name+'.command.json'), command)
            with (out/(name+'.compile.log')).open('x') as log:
                build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=30)
            assert build.returncode == 0, (name, 'compile', build.returncode)
            start = time.monotonic()
            with (out/(name+'.log')).open('x') as log:
                native = subprocess.run(['/usr/bin/vvp', str(binary)], stdout=log,
                    stderr=subprocess.STDOUT, timeout=180)
            logtext = (out/(name+'.log')).read_text()
            marker = 'CARRY-ROTATE-MISMATCH' if expected else 'CARRY-ROTATE-TREE-OK '
            row = dict(name=name, native_exit=native.returncode,
                seconds=time.monotonic()-start, passed=native.returncode == expected and marker in logtext,
                log_sha256=sha(out/(name+'.log')), binary_sha256=sha(binary),
                result=logtext[-1500:])
            rows.append(row)
            assert row['passed'], row
    except BaseException as exc:
        import traceback
        error = dict(error=repr(exc), traceback=traceback.format_exc())
    stable = all(sha(p) == h for p, h in pins.items())
    result = dict(passed=error is None and stable and len(rows) == len(variants),
        rows=rows, error=error, pins_unchanged=stable, seconds=time.monotonic()-begin,
        invocation=os.environ['INVOCATION_ID'], whole_core=False,
        timing_mhz=None, gameplay_ipc=None, standard_suite=False, physical_board=False,
        scope='Actual helper A/B; all binary widths/counts/subops, basis/random/exhaustive byte; unknown count controls. Not whole-RTL formal proof.')
    save(out/'closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
