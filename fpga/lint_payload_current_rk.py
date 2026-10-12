#!/usr/bin/env python3
"""Adapt the strict frozen-core lint admission for exactly the new 157th flag."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import lint_frozen_rk_core as base
from freeze_payload_current_rk_candidate import hardware_profile, recipe


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'out'): ap.add_argument('--'+name, required=True, type=Path)
    ap.add_argument('--manifest-sha256', required=True)
    args = ap.parse_args()
    source, root = args.source.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root != scratch and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    defs = (source/'defines.txt').read_text().splitlines()
    assert len(defs) == 157 and defs[153] == recipe.payload.FLAG
    assert hardware_profile(defs[:153]+defs[154:], sorted(set(defs)-{'SYNTHESIS', 'VTM_NO_DPI'})) == defs
    original = Path(base.__file__)
    text = original.read_text()
    for old, new in (
        ('REPO = Path(__file__).resolve().parents[1]', 'REPO = Path('+repr(str(base.REPO))+')'),
        ('len(definitions) == len(set(definitions)) == 156',
         'len(definitions) == len(set(definitions)) == 157 and definitions[153] == '+repr(recipe.payload.FLAG))):
        assert text.count(old) == 1
        text = text.replace(old, new)
    driver = root.with_suffix('.driver.py')
    with driver.open('x') as stream:
        stream.write('import sys\nsys.path.insert(0, '+repr(str(original.parent))+')\n'+text)
    pins = {str(p): base.sha(p) for p in (Path(__file__), original, driver,
            original.with_name('freeze_payload_current_rk_candidate.py'))}
    command = [sys.executable, '-B', str(driver), '--source', str(source), '--out', str(root),
               '--manifest-sha256', args.manifest_sha256]
    with root.with_suffix('.driver.json').open('x') as stream:
        json.dump(dict(command=command, pins=pins, strict_warnings_unchanged=True), stream, indent=2)
    native = subprocess.run(command)
    assert all(base.sha(p) == h for p,h in pins.items())
    return native.returncode


if __name__ == '__main__':
    raise SystemExit(main())
