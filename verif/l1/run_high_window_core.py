#!/usr/bin/env python3
"""Use the unchanged cold-system FP/integer corpora for the high-window mux."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import run_response_payload_core as base
from prepare_high_window_payload import FLAG


def adapt(source, suite):
    text = base.adapt(source, suite)
    before = "added = {'"+base.FLAG+"'}" if suite == 'fp' else "flag = '"+base.FLAG+"'"
    after = "added = {'"+FLAG+"'}" if suite == 'fp' else "flag = '"+FLAG+"'"
    if text.count(before) != 1:
        raise ValueError('missing/ambiguous profile admission')
    return text.replace(before, after)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=('fp', 'integer'), required=True)
    parser.add_argument('--out', type=Path, required=True)
    args, remainder = parser.parse_known_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert args.out.resolve().is_relative_to(scratch) and not args.out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    source = (base.REPO/'verif/issue_uv/run-fp-high-payload-ab.py' if args.suite == 'fp'
              else base.HERE/'run_store_warm_core.py')
    driver = args.out.parent/(args.out.name+'.driver.py')
    with driver.open('x') as f:
        f.write(adapt(source.read_text(), args.suite))
    pins = {str(p): base.sha(p) for p in (Path(__file__), Path(base.__file__), source, driver)}
    command = [sys.executable, '-B', str(driver), '--out', str(args.out), *remainder]
    with driver.with_suffix('.json').open('x') as f:
        json.dump(dict(command=command, pins=pins, added_define=FLAG,
            suite=args.suite, complete_cycle_equality_required=True), f, indent=2)
    native = subprocess.run(command, pass_fds=(9,))
    assert all(base.sha(p) == h for p, h in pins.items())
    return native.returncode


if __name__ == '__main__':
    sys.exit(main())
