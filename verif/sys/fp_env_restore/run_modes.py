"""Use the unchanged native/full-trace runner for 48 mode/size/offset cases.

Only fixture paths and case enumeration differ. Retain every native failure
and complete comparator result, including the known real-32 store-layout gap.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'obsolete_fp'))
from run_probe import sha


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('core','out'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();root=a.out.resolve();scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    original=HERE.parent/'obsolete_fp/run_repaired.py';text=original.read_text()
    assert text.count("HERE/'state.S'")==2 and text.count("HERE/'state.ld'")==2
    text=text.replace("HERE/'state.S'",'Path('+repr(str(HERE/'restore.S'))+')')
    text=text.replace("HERE/'state.ld'",'Path('+repr(str(HERE/'restore.ld'))+')')
    begin=text.index('        defs=[dict(OPCODE=');end=text.index('    root.mkdir()',begin)
    text=text[:begin]+'''        defs=[dict(MODE=m,ENV16=e,FULL=f,SHIFT=s,PENDING=0,PREFIX=0,LOCKED=0,CONTROL=1)
              for m,e,f,s in itertools.product((0,1,2),(0,1),(0,1),(0,1,63,4090))]
        cases=[dict(defines=c,image=None,name='-'.join(k.lower()+str(v) for k,v in c.items())) for c in defs]
'''+text[end:]
    driver=root.with_suffix('.driver.py')
    with driver.open('x') as stream:
        stream.write('import sys\nsys.path.insert(0, '+repr(str(original.parent))+')\n'+text)
    pins={str(p):sha(p) for p in (Path(__file__),original,driver,HERE/'restore.S',HERE/'restore.ld')}
    command=[sys.executable,'-B',str(driver),'--phase','state','--core',str(a.core.resolve(strict=True)),
             '--out',str(root)]
    with root.with_suffix('.driver.json').open('x') as stream:
        json.dump(dict(pins=pins,command=command,comparison_unchanged=True,cases=48),stream,indent=2)
    result=subprocess.run(command,timeout=300)
    assert all(sha(p)==h for p,h in pins.items())
    return result.returncode


if __name__=='__main__':raise SystemExit(main())
