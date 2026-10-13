"""Build the leaf-checked environment-pointer repair on the frozen UV core."""
import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]
spec=importlib.util.spec_from_file_location('fp_environment_recipe',HERE/'prepare.py')
recipe=importlib.util.module_from_spec(spec);spec.loader.exec_module(recipe)
sys.path.insert(0,str(REPO/'verif/sys/lmsw'))
from build_lmsw_core import native, BUILDER_SHA

MODEL='2fc497047dc64848f28a920522a6fa4ec1e8ef0c686179394576d6237402acb2'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','leaf','out'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();parent=a.parent.resolve(strict=True);leaf=a.leaf.resolve(strict=True);root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3 and native.sha(native.__file__)==BUILDER_SHA
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    old,built=native.load(parent/'build-started.json'),native.load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    checked,started=native.load(leaf/'closed.json'),native.load(leaf/'started.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors'] and not checked['whole_core']
    assert len(checked['rows'])==2 and all(r['build_exit']==0 for r in checked['rows'])
    assert checked['rows'][0]['name']=='parent' and checked['rows'][0]['native_exit'] in (-6,1,134)
    assert 'ENV-POINTER mode=0 full=0 sample=0' in checked['rows'][0]['log']
    assert checked['rows'][1]['name']=='repaired' and checked['rows'][1]['native_exit']==0
    assert 'FP-ENV-RESTORE-OK cases=1024' in checked['rows'][1]['log']
    source=parent/'candidate';files=native.common.candidate_files(source)
    assert len(files)==195 and all(native.sha(p)==old['pins'][str(p)] for p in files)
    flags=[s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0])
    assert len(definitions)==len(set(definitions))==152 and definitions==started['definitions']
    changes={name:recipe.transform((source/name).read_text(),name) for name in recipe.PARENTS}
    assert all(text==(leaf/'repaired/source'/name).read_text() for name,text in changes.items())
    pins=dict(old['pins']);pins.update(started['pins'])
    for row in checked['rows']:pins.update(row['artifacts'])
    for p in (Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(native.common.__file__),
        REPO/'verif/sys/lmsw/build_lmsw_core.py',HERE/'test_prepare.py',leaf/'closed.json',
        parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium'):
        pins[str(p.resolve())]=native.sha(p)
    assert native.stable(pins)
    root.mkdir();shutil.copytree(source,root/'candidate')
    for name,text in changes.items():(root/'candidate'/name).write_text(text)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert [p for p in names if native.sha(source/p)!=native.sha(root/'candidate'/p)]==sorted(recipe.PARENTS)
    host=root/('tb_fp_env_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/p):native.sha(root/'candidate'/p) for p in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=sorted(recipe.PARENTS),compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None))
    native.MODEL=MODEL;native.CHANGES=sorted(recipe.PARENTS)
    return native.build(root)


if __name__=='__main__':raise SystemExit(main())
