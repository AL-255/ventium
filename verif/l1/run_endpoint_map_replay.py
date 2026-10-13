"""Exact-input canonical trace replay for the one-file endpoint-map derivative.

Use the existing complete-record comparator and 152-definition adapter.
This establishes regression equivalence, never a waiver of canonical failures.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import prepare_endpoint_map as recipe
import run_canonical_same_input_ab as original

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/sys/smsw_memory'))
from run_regression import adapt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','candidate','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    args = parser.parse_args()
    parent = args.parent.resolve(strict=True); candidate = args.candidate.resolve(strict=True)
    out = args.out.resolve(); scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    prepared = json.loads((candidate/'prepared.json').read_text())
    assert Path(prepared['parent']).resolve(strict=True) == parent
    assert prepared['changes'] == [recipe.FILE]
    assert len(prepared['definitions']) == len(set(prepared['definitions'])) == 152
    assert recipe.transform((parent/'candidate'/recipe.FILE).read_text()) == (candidate/'candidate'/recipe.FILE).read_text()
    assert all(original.sha(Path(p)) == h for p,h in prepared['pins'].items())
    source = Path(original.__file__); driver = out.with_suffix('.driver.py')
    with driver.open('x') as stream:
        stream.write('import sys\nsys.path.insert(0, '+repr(str(source.parent))+')\n'+adapt(source.read_text()))
    pins = {str(p):original.sha(p) for p in
            (Path(__file__),Path(recipe.__file__),REPO/'verif/sys/smsw_memory/run_regression.py',
             source,driver,candidate/'prepared.json')}
    command = [sys.executable,'-B',str(driver),'--parent',str(parent),
               '--candidate',str(candidate),'--out',str(out)]
    with out.with_suffix('.driver.json').open('x') as stream:
        json.dump(dict(command=command,pins=pins,definitions_identical=True,definition_count=152,
                       original_full_trace_comparison=True,gameplay_ipc=None),stream,indent=2)
    native = subprocess.run(command,timeout=590)
    assert all(original.sha(Path(p)) == h for p,h in pins.items())
    return native.returncode


if __name__ == '__main__':
    raise SystemExit(main())
