"""Replay full canonical traces against the unchanged LMSW parent.

Admit only the five explicit RTL changes and the identical 152-define profile.
Use the existing exact-record comparator, never a waiver of the QEMU gate.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import prepare_lmsw as recipe
from run_probe import HERE, REPO, sha
sys.path.insert(0, str(REPO/'verif/l1'))
import run_canonical_same_input_ab as original


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','candidate','out'): parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    parent,candidate=args.parent.resolve(strict=True),args.candidate.resolve(strict=True)
    out=args.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    prepared=json.loads((candidate/'prepared.json').read_text())
    assert Path(prepared['parent']).resolve(strict=True)==parent
    assert prepared['changes']==sorted('rtl/core/'+name for name in recipe.PARENTS)
    assert len(prepared['definitions'])==len(set(prepared['definitions']))==152
    for name in recipe.PARENTS:
        assert recipe.transform((parent/'candidate/rtl/core'/name).read_text(),name)==(candidate/'candidate/rtl/core'/name).read_text()
    assert all(sha(p)==h for p,h in prepared['pins'].items())
    source=Path(original.__file__); driver=out.with_suffix('.driver.py')
    text=source.read_text()
    anchor='    assert profiles[0]==profiles[1] and len(profiles[0])==150'
    assert text.count(anchor)==1
    text=text.replace(anchor,anchor[:-3]+'152')
    with driver.open('x') as stream:
        stream.write('import sys\nsys.path.insert(0, '+repr(str(source.parent))+')\n'+text)
    pins={str(p):sha(p) for p in (Path(__file__),Path(recipe.__file__),source,driver,candidate/'prepared.json')}
    command=[sys.executable,'-B',str(driver),'--parent',str(parent),'--candidate',str(candidate),'--out',str(out)]
    with out.with_suffix('.driver.json').open('x') as stream:
        json.dump(dict(pins=pins,command=command,definitions_identical=True,
            original_full_trace_comparison=True,gameplay_ipc=None),stream,indent=2)
    native=subprocess.run(command,timeout=590)
    assert all(sha(p)==h for p,h in pins.items())
    return native.returncode


if __name__=='__main__': raise SystemExit(main())
