"""Full same-input canonical replay; pointer fixes do not waive QEMU failures."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]
spec=importlib.util.spec_from_file_location('fp_environment_recipe',HERE/'prepare.py')
recipe=importlib.util.module_from_spec(spec);spec.loader.exec_module(recipe)
sys.path.insert(0,str(REPO/'verif/l1'))
import run_canonical_same_input_ab as original


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','candidate','out'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();parent=a.parent.resolve(strict=True);core=a.candidate.resolve(strict=True);out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    prepared=json.loads((core/'prepared.json').read_text())
    assert Path(prepared['parent']).resolve()==parent
    assert prepared['changes']==sorted(recipe.PARENTS)
    assert len(prepared['definitions'])==len(set(prepared['definitions']))==152
    for name in recipe.PARENTS:
        assert recipe.transform((parent/'candidate'/name).read_text(),name)==(core/'candidate'/name).read_text()
    assert all(original.sha(Path(p))==h for p,h in prepared['pins'].items())
    source=Path(original.__file__);driver=out.with_suffix('.driver.py');text=source.read_text()
    anchor='    assert profiles[0]==profiles[1] and len(profiles[0])==150'
    assert text.count(anchor)==1;text=text.replace(anchor,anchor[:-3]+'152')
    with driver.open('x') as stream:
        stream.write('import sys\nsys.path.insert(0, '+repr(str(source.parent))+')\n'+text)
    pins={str(p):original.sha(p) for p in (Path(__file__),Path(recipe.__file__),source,driver,core/'prepared.json')}
    command=[sys.executable,'-B',str(driver),'--parent',str(parent),'--candidate',str(core),'--out',str(out)]
    with out.with_suffix('.driver.json').open('x') as stream:
        json.dump(dict(pins=pins,command=command,original_full_trace_comparison=True,
            definitions_identical=True,gameplay_ipc=None),stream,indent=2)
    native=subprocess.run(command,timeout=590)
    assert all(original.sha(Path(p))==h for p,h in pins.items())
    return native.returncode


if __name__=='__main__':raise SystemExit(main())
