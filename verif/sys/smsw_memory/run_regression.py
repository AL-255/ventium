"""Replay canonical parent/SMSW traces on identical inputs and stack state.

Only adapt the historical profile cardinality from 150 to 152. Require exact
profile equality, preserve all comparisons, and never waive the red QEMU gate.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2]/'verif/l1'))
import run_canonical_same_input_ab as original


def adapt(source):
    old = '    assert profiles[0]==profiles[1] and len(profiles[0])==150'
    if source.count(old) != 1:
        raise ValueError('canonical replay profile contract drift')
    return source.replace(old, old[:-3]+'152')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'candidate', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    parent, candidate = [getattr(args,key).resolve(strict=True) for key in ('parent','candidate')]
    prepared = json.loads((candidate/'prepared.json').read_text())
    assert Path(prepared['parent']).resolve(strict=True) == parent
    assert len(prepared['definitions']) == len(set(prepared['definitions'])) == 152
    assert prepared['changes'] == sorted('rtl/core/'+name for name in
        ('core.sv','decode_stages.sv','core_fetch_decode.svh'))
    assert all(original.sha(Path(path)) == value for path,value in prepared['pins'].items())
    source = Path(original.__file__)
    driver = root.with_suffix('.driver.py')
    with driver.open('x') as stream:
        stream.write('import sys\nsys.path.insert(0, '+repr(str(source.parent))+')\n'+adapt(source.read_text()))
    pins = {str(path):original.sha(path) for path in
            (Path(__file__),source,driver,candidate/'prepared.json')}
    command = [sys.executable,'-B',str(driver),'--parent',str(parent),
               '--candidate',str(candidate),'--out',str(root)]
    with root.with_suffix('.driver.json').open('x') as stream:
        json.dump(dict(command=command,pins=pins,definitions_identical=True,definition_count=152,
                       original_full_trace_comparison=True,gameplay_ipc=None),stream,indent=2)
    child = subprocess.run(command,timeout=590)
    assert all(original.sha(Path(path)) == value for path,value in pins.items())
    return child.returncode


if __name__ == '__main__':
    raise SystemExit(main())
