#!/usr/bin/env python3
"""Reuse strict cold-system corpora for a cycle-identical response-mux change.

Archive the exact adapted driver. Keep original fixtures, QEMU comparison,
UV/fast-path witnesses and native close grading. No golden/mask/band edits.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
FLAG = 'VEN_L1D_RESPONSE_PAYLOAD_SELECT'


def adapt(source, suite):
    if suite == 'fp':
        replacements = {
            "HERE = Path(__file__).resolve().parent": "HERE = Path("+repr(str(REPO/'verif/issue_uv'))+")",
            "added = {'VEN_FP_LOAD64_PAYLOAD_SELECT'}": "added = {'"+FLAG+"'}",
        }
    elif suite == 'integer':
        replacements = {
            "HERE = Path(__file__).resolve().parent": "HERE = Path("+repr(str(HERE))+")",
            "flag = 'VEN_L1D_STORE_WINDOW_WARM'": "flag = '"+FLAG+"'",
            "default=4, choices=range(1, 5)": "default=32, choices=range(1, 33)",
            '        measures = []': '        measures = []\n        cycle_records = {}',
            "                rows = traces['cycle']": "                rows = traces['cycle']\n"
                "                cycle_records[latency, name] = rows",
            "        save(leaf/'closed.json', dict(passed=True, measurements=measures, image_sha256=sha(image)))":
                "        for latency in (0, 7):\n"
                "            assert cycle_records[latency, 'control'] == cycle_records[latency, 'candidate'], "
                "(case, latency, 'complete cycle stream changed')\n"
                "        save(leaf/'closed.json', dict(passed=True, measurements=measures, image_sha256=sha(image)))",
            "        assert any(r['saved_clocks']>0 for r in deltas if r['case'][0]==0)":
                "        assert all(r['saved_clocks']==0 for r in deltas)",
        }
    else:
        raise ValueError('unknown corpus')
    for old,new in replacements.items():
        if source.count(old) != 1:
            raise ValueError('corpus contract changed: '+old)
        source = source.replace(old,new)
    return source


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--suite',choices=('fp','integer'),required=True)
    p.add_argument('--out',type=Path,required=True)
    args, remainder = p.parse_known_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert args.out.resolve().is_relative_to(scratch) and not args.out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    source = (REPO/'verif/issue_uv/run-fp-high-payload-ab.py' if args.suite=='fp'
              else HERE/'run_store_warm_core.py')
    original = source.read_text()
    driver = args.out.parent/(args.out.name+'.driver.py')
    with driver.open('x') as f:
        f.write(adapt(original,args.suite))
    pins = {str(f):sha(f) for f in (Path(__file__),source,driver)}
    command = [sys.executable,'-B',str(driver),'--out',str(args.out),*remainder]
    with driver.with_suffix('.json').open('x') as f:
        json.dump(dict(command=command,pins=pins,added_define=FLAG,suite=args.suite,
                       complete_cycle_equality_required=True),f,indent=2)
    native = subprocess.run(command,pass_fds=(9,))
    assert all(sha(f)==h for f,h in pins.items())
    return native.returncode


if __name__=='__main__':
    sys.exit(main())
