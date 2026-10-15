"""Identity-only adapters for existing functional/replay/system checks.

Keep the unchanged worker, trace format, complete A/B records and AXI latency
controls. The qualified private reference is not a canonical-gate substitute.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import prepare_fetch_metadata_owner as recipe
from build_fetch_metadata_core import MODEL as PARENT_MODEL

REPO=Path(__file__).resolve().parents[2]
SOURCES={
    'func':('verif/qemu-trace/c1_reference/run_func.py',
            '9e5e78a4f70e1fff7a2894cda8d7d3ba6dc0cc2006400f7a958b1f4cdc98062f'),
    'replay':('verif/l1/run_window_current_same_input.py',
              '60eaf87e536a6fc3a24467c4a294433cde3ccf484bcb7eaa919ee7b95a369890'),
    'system':('verif/segment_extent/run_fast_segment_system.py',
              '8ce6e23f796cb5e366ee340c89a1ca3fa464c3af2f356a894efdcd9ec004a29e')}


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def derive(mode,core,parent,model,func,out,jobs):
    name,digest=SOURCES[mode];source=REPO/name;text=source.read_text()
    assert hashlib.sha256(text.encode()).hexdigest()==digest
    changes=[('REPO=Path(__file__).resolve().parents[3]','REPO=Path('+repr(str(REPO))+')')] if mode=='func' else [
        ('REPO = Path(__file__).resolve().parents[2]','REPO = Path('+repr(str(REPO))+')')] if mode=='replay' else [
        ('REPO=Path(__file__).resolve().parents[2]','REPO=Path('+repr(str(REPO))+')')]
    if mode=='func':
        changes += [("assert sha(model)=='369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150'",
                     'assert sha(model)=='+repr(model)),
                    ("jobs_file=core/'generic-work/jobs.txt'",'jobs_file=Path('+repr(str(jobs))+')')]
    elif mode=='replay':
        changes += [("root = evidence / 'window-current-same-input-r1'",'root = Path('+repr(str(out))+')'),
                    ("func = evidence / 'window-current-func-r1'",'func = Path('+repr(str(func))+')'),
                    ("('parent', 'env-write-core-r1'), ('candidate', 'window-current-core-r1')",
                     "('parent', "+repr(str(parent))+"), ('candidate', "+repr(str(core))+")"),
                    ('360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779',PARENT_MODEL),
                    ('737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7',model)]
    else:
        changes += [('import prepare_fast_segment as recipe','import prepare_fetch_metadata_owner as recipe'),
                    ('139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7',PARENT_MODEL),
                    ('1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c',model)]
    for before,after in changes:
        assert text.count(before)==1,before;text=text.replace(before,after)
    compile(text,str(source),'exec')
    return text,changes,source


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('mode',choices=tuple(SOURCES))
    for n in ('core','out'):ap.add_argument('--'+n,type=Path,required=True)
    ap.add_argument('--func',type=Path)
    a=ap.parse_args();core=a.core.resolve(strict=True);out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert out.is_relative_to(scratch) and not out.exists()
    started=json.loads((core/'build-started.json').read_text());closed=json.loads((core/'build-closed.json').read_text())
    parent=Path(started['parent']);model=closed['binary_sha256']
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit']==0
    assert sha(core/'obj/tb_ventium')==model and sha(parent/'obj/tb_ventium')==PARENT_MODEL
    assert started['changes']==[recipe.FILE]
    assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()
    assert all(sha(p)==h for p,h in started['pins'].items())
    func=a.func.resolve(strict=True) if a.func else None
    jobs=parent/'generic-work/jobs.txt'
    text,changes,source=derive(a.mode,core,parent,model,func,out,jobs)
    driver=out.with_suffix('.driver.py')
    with driver.open('x') as f:f.write(text)
    env=dict(os.environ,PYTHONPATH=os.pathsep.join((str(Path(__file__).parent),str(REPO/'verif/segment_extent'))))
    if a.mode=='func':
        oracle=scratch/'ventium-fprem-sequence.iSZ9BAj4'
        assert sha(oracle/'build-exceptions-r1/build/qemu-i386')=='b81831c8976043f8d8d6fc7eeb1d1a981337ca274848f2fcc32b2d3fffbf8e48'
        tail=['--core',str(core),'--out',str(out),'--build',str(oracle/'build-exceptions-r1'),
              '--probe',str(oracle/'exception-state-r2')]
    elif a.mode=='replay':
        assert func;tail=[]
    else:tail=['--parent',str(parent),'--core',str(core),'--out',str(out)]
    pins={str(p.resolve()):sha(p) for p in (Path(__file__),Path(recipe.__file__),source,driver,
        core/'build-started.json',core/'build-closed.json',core/'obj/tb_ventium',parent/'obj/tb_ventium')}
    command=[sys.executable,'-B',str(driver),*tail]
    with out.with_suffix('.driver.json').open('x') as f:
        json.dump(dict(pins=pins,command=command,substitutions=changes,mode=a.mode,
                       comparison_policy_unchanged=True),f,indent=2)
    code=subprocess.run(command,env=env,timeout=600).returncode
    stable=all(sha(p)==h for p,h in pins.items())
    with out.with_suffix('.driver-closed.json').open('x') as f:
        json.dump(dict(native_exit=code,pins_unchanged=stable),f,indent=2)
    assert stable
    return code


if __name__=='__main__':raise SystemExit(main())
