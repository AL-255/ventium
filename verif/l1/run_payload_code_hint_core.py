#!/usr/bin/env python3
"""Qualify the payload-kind port with unchanged whole-core QEMU corpora.

Only the exact added define is admitted. Keep fault fixtures, complete
architectural comparisons, paired execution witnesses and cycle equality.
This does not replace the canonical gate or the standard suite.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import run_response_payload_core as base
from prepare_payload_code_hint import FLAG

SOURCES = {
    'fp': base.REPO/'verif/issue_uv/run-fp-high-payload-ab.py',
    'integer': base.HERE/'run_store_warm_core.py',
    'faults': base.HERE/'run_fp_read_ack_faults.py',
}


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('missing/ambiguous corpus contract: '+old)
    return text.replace(old, new)


def adapt(source, suite):
    if suite in ('fp', 'integer'):
        text = base.adapt(source, suite)
        old = ("added = {'"+base.FLAG+"'}" if suite == 'fp'
               else "flag = '"+base.FLAG+"'")
        return replace_once(text, old, old.replace(base.FLAG, FLAG))
    if suite != 'faults':
        raise ValueError('unknown corpus')
    text = replace_once(source, 'REPO = Path(__file__).resolve().parents[2]',
                        'REPO = Path('+repr(str(base.REPO))+')')
    return replace_once(text, '    assert profiles[0] == profiles[1]',
                        '    assert '+repr(FLAG)+' not in profiles[0]\n'
                        '    assert profiles[1] == profiles[0] | {'+repr(FLAG)+'}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=tuple(SOURCES), required=True)
    parser.add_argument('--out', type=Path, required=True)
    args, remainder = parser.parse_known_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and out != scratch and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    source = SOURCES[args.suite]
    driver = out.parent/(out.name+'.driver.py')
    with driver.open('x') as stream:
        stream.write(adapt(source.read_text(), args.suite))
    pins = {str(path): base.sha(path) for path in (
        Path(__file__), Path(base.__file__), base.HERE/'prepare_payload_code_hint.py', source, driver)}
    command = [sys.executable, '-B', str(driver), '--out', str(out), *remainder]
    with driver.with_suffix('.json').open('x') as stream:
        json.dump(dict(command=command, pins=pins, added_define=FLAG, suite=args.suite,
                       complete_architectural_comparison=True,
                       complete_cycle_equality_required=args.suite != 'faults',
                       gameplay_ipc=None, standard_suite=False), stream, indent=2)
    native = subprocess.run(command, pass_fds=(9,))
    assert all(base.sha(path) == digest for path, digest in pins.items())
    return native.returncode


if __name__ == '__main__':
    raise SystemExit(main())
