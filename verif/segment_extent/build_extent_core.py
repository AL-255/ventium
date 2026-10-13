"""Build the exact leaf-proved segment-extent rewrite on the LMSW core.

Preserve source closure, UV-fast profile and private model-specific host object.
No canonical-gate waiver or inherited timing/standard-suite/FPGA acceptance.
"""
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
REPO=HERE.parents[1]
spec=importlib.util.spec_from_file_location('segment_extent_recipe',HERE/'prepare.py')
recipe=importlib.util.module_from_spec(spec); spec.loader.exec_module(recipe)
sys.path.insert(0,str(REPO/'verif/sys/lmsw'))
from build_lmsw_core import native, BUILDER_SHA

MODEL='fddb1fd3f7b677c44ddcc320808a9b756e45adc38718ff4d08b1dedb94d6b52b'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','leaf','out'): parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    parent,leaf=args.parent.resolve(strict=True),args.leaf.resolve(strict=True)
    root=args.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert shutil.disk_usage(scratch).free>5*1024**3 and scratch.stat().st_dev!=REPO.stat().st_dev
    assert native.sha(native.__file__)==BUILDER_SHA
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
    old,built=native.load(parent/'build-started.json'),native.load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    checked=native.load(leaf/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked['whole_core'] and not checked['errors']
    assert [(r['name'],r['build_exit'],r['native_exit']) for r in checked['rows']]==[
        ('positive',0,0),('zero-underflow-lost',0,1),('adjacent-block-lost',0,1)]
    assert [(q['name'],q['result']) for q in checked['queries']]==[
        ('equivalence','unsat'),('zero-count-needed','sat'),('adjacent-block-needed','sat')]
    assert 'SEG-EXTENT-OK vectors=2852512' in checked['rows'][0]['log']
    pins=dict(old['pins']); pins.update(checked['pins'])
    for row in checked['rows']: pins.update(row['artifacts'])
    source=parent/'candidate'; files=native.common.candidate_files(source)
    assert len(files)==195 and all(native.sha(p)==old['pins'][str(p)] for p in files)
    flags=[s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    defs=re.findall(r'\+define\+(\w+)',flags[0])
    assert len(defs)==len(set(defs))==152
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT'}<=set(defs)
    changed=recipe.transform((source/recipe.FILE).read_text())
    assert changed==(leaf/'candidate'/recipe.FILE).read_text()
    for p in (Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(native.common.__file__),
              REPO/'verif/sys/lmsw/build_lmsw_core.py',leaf/'closed.json',
              parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium'):
        pins[str(p.resolve())]=native.sha(p)
    assert native.stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    (root/'candidate'/recipe.FILE).write_text(changed)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert [p for p in names if native.sha(source/p)!=native.sha(root/'candidate'/p)]==[recipe.FILE]
    host=root/('tb_segment_extent_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/p):native.sha(root/'candidate'/p) for p in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=defs,changes=[recipe.FILE],compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None))
    native.MODEL=MODEL; native.CHANGES=[recipe.FILE]
    return native.build(root)


if __name__=='__main__': raise SystemExit(main())
