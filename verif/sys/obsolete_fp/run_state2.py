"""Run the unchanged full-state comparator with non-destructive state setup.

Keep failed FNSAVE/FRSTOR roundtrip fixtures and logs. Only the fixture source
changes: all 108 saved bytes, faults, native exits and full traces still count.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from run_probe import HERE, sha


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('core','out'):parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    root=args.out.resolve();scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    original=HERE/'run_repaired.py';text=original.read_text()
    assert text.count("HERE/'state.S'")==2
    text=text.replace("HERE/'state.S'","HERE/'state2.S'")
    driver=root.with_suffix('.driver.py')
    with driver.open('x') as stream:
        stream.write('import sys\nsys.path.insert(0, '+repr(str(HERE))+')\n'+text)
    pins={str(p):sha(p) for p in (Path(__file__),original,driver,HERE/'state2.S',HERE/'state.ld')}
    command=[sys.executable,'-B',str(driver),'--phase','state','--core',str(args.core.resolve(strict=True)),
             '--out',str(root)]
    with root.with_suffix('.driver.json').open('x') as stream:
        json.dump(dict(pins=pins,command=command,comparison_unchanged=True),stream,indent=2)
    result=subprocess.run(command,timeout=240)
    assert all(sha(p)==h for p,h in pins.items())
    return result.returncode


if __name__=='__main__':raise SystemExit(main())
