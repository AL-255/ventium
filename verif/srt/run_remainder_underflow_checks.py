"""Identity-only adapters for the unchanged functional and system workers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import prepare_remainder_underflow_core as recipe
REPO = Path(__file__).resolve().parents[2]
PARENT = '2ac15c8ba4fd6fbfcfb2dccb0daa0bb41448e7756b6abd2b2e32b8a92684bc1e'
MODEL = '77c0c895122a6d7c890924e4806af51d287cd64c5d2094aa9eaa8032079fab1d'
SOURCES = {
    'func': ('verif/qemu-trace/c1_reference/run_func.py',
             '9e5e78a4f70e1fff7a2894cda8d7d3ba6dc0cc2006400f7a958b1f4cdc98062f'),
    'system': ('verif/segment_extent/run_fast_segment_system.py',
               '8ce6e23f796cb5e366ee340c89a1ca3fa464c3af2f356a894efdcd9ec004a29e')}


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def derive(mode, parent):
    filename,digest = SOURCES[mode]; source = REPO/filename; original = source.read_text()
    assert sha(source) == digest
    if mode == 'func':
        changes = [('REPO=Path(__file__).resolve().parents[3]', 'REPO=Path('+repr(str(REPO))+')'),
            ("assert sha(model)=='369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150'",
             'assert sha(model)=='+repr(MODEL)),
            ("jobs_file=core/'generic-work/jobs.txt'",'jobs_file=Path('+repr(str(parent/'generic-work/jobs.txt'))+')')]
    else:
        changes = [('REPO=Path(__file__).resolve().parents[2]', 'REPO=Path('+repr(str(REPO))+')'),
            ('import prepare_fast_segment as recipe','import prepare_remainder_underflow_core as recipe'),
            ('139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7',PARENT),
            ('1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c',MODEL),
            ("assert recipe.transform((parent/'candidate'/recipe.FILE).read_text())==(core/'candidate'/recipe.FILE).read_text()",
             "assert all(recipe.transform((parent/'candidate'/n).read_text(),n)==(core/'candidate'/n).read_text() for n in recipe.PARENTS)")]
    text = original
    for old,new in changes: text = recipe.leaf.once(text,old,new)
    recovered = text
    for old,new in reversed(changes): recovered = recipe.leaf.once(recovered,new,old)
    assert recovered == original
    compile(text,str(source),'exec')
    return source,text,changes


def main():
    ap = argparse.ArgumentParser(description=__doc__); ap.add_argument('mode',choices=tuple(SOURCES))
    for n in ('core','out'): ap.add_argument('--'+n,type=Path,required=True)
    a = ap.parse_args(); core = a.core.resolve(strict=True); out = a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    started,built = [json.loads((core/n).read_text()) for n in ('build-started.json','build-closed.json')]
    parent = Path(started['parent'])
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert sha(core/'obj/tb_ventium') == built['binary_sha256'] == MODEL
    assert sha(parent/'obj/tb_ventium') == PARENT
    assert started['changes'] == sorted(recipe.PARENTS) and not started['rejected_metadata_inherited']
    assert all(recipe.transform((parent/'candidate'/n).read_text(),n)==(core/'candidate'/n).read_text() for n in recipe.PARENTS)
    assert all(sha(p)==h for p,h in started['pins'].items())
    source,text,changes = derive(a.mode,parent)
    driver = out.with_suffix('.driver.py')
    with driver.open('x') as f: f.write(text)
    oracle = scratch/'ventium-fprem-sequence.iSZ9BAj4'
    if a.mode == 'func':
        assert sha(oracle/'build-underflow-r1/build/qemu-i386') == '998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85'
        tail = ['--core',core,'--out',out,'--build',oracle/'build-underflow-r1',
                '--probe',oracle/'srt-underflow-r2']
    else: tail = ['--parent',parent,'--core',core,'--out',out]
    pins = {str(p.resolve()):sha(p) for p in (Path(__file__),Path(recipe.__file__),Path(recipe.leaf.__file__),
        source,driver,core/'build-started.json',core/'build-closed.json',core/'obj/tb_ventium',parent/'obj/tb_ventium')}
    command = list(map(str,[sys.executable,'-B',driver,*tail]))
    with out.with_suffix('.driver.json').open('x') as f:
        json.dump(dict(pins=pins,command=command,substitutions=changes,comparison_policy_unchanged=True),f,indent=2)
    env = dict(os.environ,PYTHONPATH=os.pathsep.join((str(Path(__file__).parent),str(REPO/'verif/segment_extent'))))
    code = subprocess.run(command,env=env,timeout=600).returncode
    stable = all(sha(p)==h for p,h in pins.items())
    with out.with_suffix('.driver-closed.json').open('x') as f:
        json.dump(dict(native_exit=code,pins_unchanged=stable),f,indent=2)
    assert stable; return code


if __name__ == '__main__': raise SystemExit(main())
