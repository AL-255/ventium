"""Build the proved segment-admission factorization on the current timing core."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess

from build_data_size_core import native
import prepare_fast_segment as recipe

REPO = Path(__file__).resolve().parents[2]
MODEL = '139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','leaf','out'): ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args(); parent=a.parent.resolve(strict=True); leaf=a.leaf.resolve(strict=True); root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    assert os.sched_getaffinity(0)==set(range(32))-{11}
    assert native.sha(native.__file__)=='9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
    old=native.load(parent/'build-started.json'); built=native.load(parent/'build-closed.json')
    checked=native.load(leaf/'closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert built['binary_sha256']==native.sha(parent/'obj/tb_ventium')==MODEL
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert len(checked['rows'])==8 and all(r['build_exit']==0 for r in checked['rows'])
    assert [(q['name'],q['result']) for q in checked['queries']]==[
        ('equivalence','unsat'),('wrong-segment','sat'),('expand-down','sat'),
        ('inclusive-page','sat'),('word-boundary','sat')]
    source=parent/'candidate'; files=native.common.candidate_files(source)
    assert len(files)==195 and all(native.sha(p)==old['pins'][str(p)] for p in files)
    flags=[s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    assert '-GAXI_LINE_REPLAY=0' in flags[0]
    definitions=re.findall(r'\+define\+(\w+)',flags[0]); assert len(set(definitions))==152
    assert definitions==native.load(leaf/'started.json')['definitions']
    changed=recipe.transform((source/recipe.FILE).read_text())
    assert changed==(leaf/'candidate'/recipe.FILE).read_text()
    pins={**old['pins'],**checked['pins']}
    for row in checked['rows']: pins.update(row['artifacts'])
    for p in (Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(native.common.__file__),
              REPO/'verif/segment_extent/build_data_size_core.py',
              leaf/'closed.json',parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium'):
        pins[str(p.resolve())]=native.sha(p)
    assert native.stable(pins)
    root.mkdir(); shutil.copytree(source,root/'candidate')
    (root/'candidate'/recipe.FILE).write_text(changed)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert [n for n in names if native.sha(source/n)!=native.sha(root/'candidate'/n)]==[recipe.FILE]
    host=root/('tb_fast_segment_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[recipe.FILE],compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None))
    native.MODEL=MODEL; native.CHANGES=[recipe.FILE]
    code=native.build(root)
    if code==0:
        actual=(root/'obj/Vventium_top__verFiles.dat').read_text()
        assert actual.count('-GAXI_LINE_REPLAY=0')==1
        assert set(re.findall(r'\+define\+(\w+)',actual))==set(definitions)
    return code


if __name__=='__main__':
    raise SystemExit(main())
