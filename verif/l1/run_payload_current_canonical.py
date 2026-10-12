#!/usr/bin/env python3
"""Replay complete canonical traces, admitting only the payload-only extra flag."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import run_canonical_same_input_ab as original
from prepare_payload_code_hint import FLAG


def adapt(source):
    old = '    assert profiles[0]==profiles[1] and len(profiles[0])==150'
    if source.count(old) != 1:
        raise ValueError('canonical replay profile contract drift')
    return source.replace(old, '    assert len(profiles[0]) == 150 and '+repr(FLAG)+' not in profiles[0]\n'
        '    assert profiles[1] == profiles[0] | {'+repr(FLAG)+'}')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'candidate', 'out'):
        ap.add_argument('--'+name, type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    source = Path(original.__file__)
    driver = root.with_suffix('.driver.py')
    with driver.open('x') as stream:
        stream.write('import sys\nsys.path.insert(0, '+repr(str(source.parent))+')\n'+adapt(source.read_text()))
    pins = {str(p): original.sha(p) for p in (Path(__file__), source, driver,
        source.with_name('prepare_payload_code_hint.py'))}
    command = [sys.executable, '-B', str(driver), '--parent', str(args.parent.resolve(strict=True)),
               '--candidate', str(args.candidate.resolve(strict=True)), '--out', str(root)]
    with root.with_suffix('.driver.json').open('x') as stream:
        json.dump(dict(command=command, pins=pins, only_added_define=FLAG,
                       original_full_trace_comparison=True, gameplay_ipc=None), stream, indent=2)
    child = subprocess.run(command)
    assert all(original.sha(Path(p)) == h for p,h in pins.items())
    return child.returncode


if __name__ == '__main__':
    raise SystemExit(main())
