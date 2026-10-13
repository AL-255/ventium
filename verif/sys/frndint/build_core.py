"""Transfer the independently audited FRNDINT repair into the full UV core."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import prepare

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]
sys.path.insert(0,str(REPO/'verif/sys/smsw_memory'))
spec=importlib.util.spec_from_file_location('frnd_native_builder',REPO/'verif/sys/smsw_memory/build_core.py')
native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
MODEL='369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','leaf','out'):ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args();parent=a.parent.resolve(strict=True);leaf=a.leaf.resolve(strict=True);root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    assert native.sha(native.__file__)=='9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    assert os.sched_getaffinity(0)==set(range(8,16))
    old,built=native.load(parent/'build-started.json'),native.load(parent/'build-closed.json')
    checked,started=native.load(leaf/'audit.json'),native.load(leaf/'started.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    assert checked['passed'] and checked['results']['repaired']['mismatches']==0
    assert checked['frndint_cases']==28612 and checked['integer_oracle_checks']==27072
    assert checked['results']['parent']['mismatches']==15952
    assert native.stable(checked['artifacts']) and native.stable(started['pins'])
    source=parent/'candidate';files=native.common.candidate_files(source)
    assert len(files)==195 and all(native.sha(p)==old['pins'][str(p)] for p in files)
    flags=[s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and 'VL_J=32' in old['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0])
    assert definitions==started['definitions'] and len(set(definitions))==152
    changes={n:prepare.transform((source/n).read_text(),n) for n in prepare.PARENTS}
    assert all(text==(leaf/'repaired/source'/n).read_text() for n,text in changes.items())
    pins=dict(old['pins']);pins.update(started['pins']);pins.update(checked['artifacts'])
    for p in (Path(__file__),Path(prepare.__file__),Path(native.__file__),Path(native.common.__file__),
              HERE/'test_prepare.py',leaf/'audit.json',parent/'build-started.json',parent/'build-closed.json',
              parent/'obj/tb_ventium'):pins[str(p.resolve())]=native.sha(p)
    assert native.stable(pins)
    root.mkdir();shutil.copytree(source,root/'candidate')
    for name,text in changes.items():(root/'candidate'/name).write_text(text)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert [n for n in names if native.sha(source/n)!=native.sha(root/'candidate'/n)]==sorted(prepare.PARENTS)
    host=root/('tb_frndint_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=sorted(prepare.PARENTS),compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None))
    native.MODEL=MODEL;native.CHANGES=sorted(prepare.PARENTS)
    return native.build(root)


if __name__=='__main__':raise SystemExit(main())
