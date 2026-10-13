"""Reuse the unmodified full-trace runner for the CPL1/2/3 and V86 matrix.

Only select fixture/cases, expected #GP and private ports. Comparison, native
success requirements, resource confinement and error handling stay unchanged.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

from run_probe import HERE, sha
from run_faults import save


def adapt(source):
    old = """    cases = [dict(CASE=c, ADDR32=a, OP32=o, LATENCY=7)
             for c,a,o in itertools.product(range(8),(0,1),(0,1))]
    cases += [dict(CASE=c, ADDR32=a, OP32=1, LATENCY=l)
              for c,a,l in itertools.product(range(3),(0,1),(0,31))]
"""
    new = """    cases = [dict(CPL=c, V86=0, MEMORY=m, ADDR32=a, OP32=o, LATENCY=7)
             for c,m,a,o in itertools.product((1,2,3),(0,1),(0,1),(0,1))]
    cases += [dict(CPL=3, V86=1, MEMORY=m, ADDR32=a, OP32=o, LATENCY=7)
              for m,a,o in itertools.product((0,1),(0,1),(0,1))]
"""
    edits = [(old,new), ("str(14100+index)","str(14300+index)"),
        ("        expected = None if c['CASE'] in (0,4) else (14 if c['CASE'] in (1,2) else 6 if c['CASE']>=6 else 13)",
         "        expected = 13")]
    for before, after in edits:
        if source.count(before) != 1: raise ValueError('privilege runner anchor drift')
        source = source.replace(before,after)
    for old_name,new_name in (('fault.S','privilege.S'),('fault.ld','privilege.ld')):
        before = "HERE/'"+old_name+"'"
        if source.count(before)!=2: raise ValueError('fixture anchor drift')
        source=source.replace(before,"HERE/'"+new_name+"'")
    return source


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('core','out'): parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    root=args.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    original=HERE/'run_faults.py'; driver=root.with_suffix('.driver.py')
    with driver.open('x') as stream:
        stream.write('import sys\nsys.path.insert(0, '+repr(str(HERE))+')\n'+adapt(original.read_text()))
    pins={str(p):sha(p) for p in (Path(__file__),original,driver,HERE/'privilege.S',HERE/'privilege.ld')}
    command=[sys.executable,'-B',str(driver),'--core',str(args.core.resolve(strict=True)),'--out',str(root)]
    save(root.with_suffix('.driver.json'),dict(pins=pins,command=command,unmodified_comparison=True))
    result=subprocess.run(command,timeout=230)
    assert all(sha(p)==h for p,h in pins.items())
    return result.returncode


if __name__=='__main__': raise SystemExit(main())
