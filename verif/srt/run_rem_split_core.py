#!/usr/bin/env python3
"""Reuse complete cold QEMU/cycle corpora for the combined SRT/V-clear cut.

Only the new SRT define is admitted. No fixture, comparison, cycle target,
mask, architectural trace or UV/fast-path witness is relaxed.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/l1'))
import run_payload_code_hint_core as corpus
import run_canonical_same_input_ab as canonical
from prepare_rem_operand_split import FLAG


def adapt(source, suite):
    if suite == 'canonical':
        old = '    assert profiles[0]==profiles[1] and len(profiles[0])==150'
        new = ('    assert len(profiles[0]) == 151 and '+repr(FLAG)+' not in profiles[0]\n'
               '    assert profiles[1] == profiles[0] | {'+repr(FLAG)+'}')
        return ('import sys\nsys.path.insert(0, '+repr(str(REPO/'verif/l1'))+')\n'
                + corpus.replace_once(source, old, new))
    text = corpus.adapt(source, suite)
    old = repr(corpus.FLAG)
    expected = 1 if suite in ('fp', 'integer') else 2
    if text.count(old) != expected:
        raise ValueError('profile adapter contract drift')
    return text.replace(old, repr(FLAG))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--suite', choices=(*corpus.SOURCES, 'canonical'), required=True)
    ap.add_argument('--out', type=Path, required=True)
    args, remainder = ap.parse_known_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert scratch.stat().st_dev != REPO.stat().st_dev
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    source = Path(canonical.__file__) if args.suite == 'canonical' else corpus.SOURCES[args.suite]
    driver = out.with_suffix('.driver.py')
    with driver.open('x') as stream:
        stream.write(adapt(source.read_text(), args.suite))
    pins = {str(p): corpus.base.sha(p) for p in (Path(__file__), source, driver,
        Path(corpus.__file__), Path(corpus.base.__file__),
        Path(__file__).with_name('prepare_rem_operand_split.py'))}
    command = [sys.executable, '-B', str(driver), '--out', str(out), *remainder]
    receipt = out.with_suffix('.driver.json')
    with receipt.open('x') as stream:
        json.dump(dict(command=command, pins=pins, added_define=FLAG, suite=args.suite,
            complete_architectural_comparison=True, gameplay_ipc=None,
            standard_suite=False), stream, indent=2)
    # Only the serialized fault corpus runs inside the build guard. Never
    # force a 32-worker native matrix under its 128-task compiler cgroup.
    fd = ()
    if args.suite == 'faults':
        os.fstat(9)
        fd = (9,)
    native = subprocess.run(command, pass_fds=fd)
    assert all(corpus.base.sha(p) == digest for p, digest in pins.items())
    return native.returncode


if __name__ == '__main__':
    raise SystemExit(main())
