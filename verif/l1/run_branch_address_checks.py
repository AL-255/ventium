"""Identity-only functional/system workers for the early-address experiment."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import prepare_branch_address_shape as recipe
REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/srt'))
import run_remainder_underflow_checks as prior

PARENT='77c0c895122a6d7c890924e4806af51d287cd64c5d2094aa9eaa8032079fab1d'
MODEL='6deb3e92ae302d2166c18d239711754c049f1f775f2518a2f5b576108eb8b16d'
sha=prior.sha


def derive(mode,parent):
    source,text,old_changes=prior.derive(mode,parent)
    changes=[(prior.MODEL,MODEL)]
    if mode=='system':
        changes += [(prior.PARENT,PARENT),
            ('import prepare_remainder_underflow_core as recipe','import prepare_branch_address_shape as recipe'),
            ("assert all(recipe.transform((parent/'candidate'/n).read_text(),n)==(core/'candidate'/n).read_text() for n in recipe.PARENTS)",
             "assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()")]
    original=text
    for old,new in changes: text=recipe.once(text,old,new)
    recovered=text
    for old,new in reversed(changes): recovered=recipe.once(recovered,new,old)
    assert recovered==original
    compile(text,str(source),'exec')
    return source,text,old_changes+changes


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('mode',choices=('func','system'))
    for n in ('core','out'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();core=a.core.resolve(strict=True);out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out!=scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    started,built=[json.loads((core/n).read_text()) for n in ('build-started.json','build-closed.json')]
    parent=Path(started['parent'])
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']==MODEL
    assert sha(parent/'obj/tb_ventium')==PARENT and started['changes']==[recipe.FILE]
    assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()
    assert all(sha(p)==h for p,h in started['pins'].items())
    source,text,changes=derive(a.mode,parent)
    driver=out.with_suffix('.driver.py')
    with driver.open('x') as f:f.write(text)
    evidence=scratch/'ventium-fprem-sequence.iSZ9BAj4'
    tail=['--core',core,'--out',out]
    if a.mode=='func':tail+=['--build',evidence/'build-underflow-r1','--probe',evidence/'srt-underflow-r2']
    else:tail+=['--parent',parent]
    command=list(map(str,[sys.executable,'-B',driver,*tail]))
    pins={str(p.resolve()):sha(p) for p in (Path(__file__),Path(recipe.__file__),Path(prior.__file__),
        source,driver,core/'build-started.json',core/'build-closed.json',core/'obj/tb_ventium',parent/'obj/tb_ventium')}
    with out.with_suffix('.driver.json').open('x') as f:
        json.dump(dict(pins=pins,command=command,substitutions=changes,comparison_policy_unchanged=True),f,indent=2)
    env=dict(os.environ,PYTHONPATH=os.pathsep.join((str(Path(__file__).parent),str(REPO/'verif/segment_extent'))))
    code=subprocess.run(command,env=env,timeout=600).returncode
    stable=all(sha(p)==h for p,h in pins.items())
    with out.with_suffix('.driver-closed.json').open('x') as f:
        json.dump(dict(native_exit=code,pins_unchanged=stable),f,indent=2)
    assert stable;return code


if __name__=='__main__':raise SystemExit(main())
