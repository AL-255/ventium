"""Build the leaf-checked compare classifier with unchanged UV-fast configuration."""
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
# Load the existing builder first: its historical sibling is also named
# prepare.py. Load this recipe by explicit path under a unique module name.
sys.path.insert(0,str(REPO/'verif/l1'))
from build_window_current_core import native
spec=importlib.util.spec_from_file_location('fp_compare_recipe',HERE/'prepare.py')
recipe=importlib.util.module_from_spec(spec);spec.loader.exec_module(recipe)
MODEL='97b11f3b4ebc54524dfe3da08fa49e42ea829d90c68481c1e029b3a5d32fcc0e'
FILE='fp_shared/ven_fp_top.sv'
LEAF='74be22ce833e249fd80b292db9b2c468b25f8a243fc1701c948e80bea1e5b59b'
AUDIT='ca4029585453809ea30a123c8b5b35b684a44e69b3badd0109fd8e12f63a3b8d'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    assert native.sha(native.__file__)=='9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'
    if args.action=='build':
        assert os.sched_getaffinity(0)==(set(range(32))-{10,11})
        assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
        subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
        assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
        subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                        'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
        native.MODEL=MODEL;native.CHANGES=[FILE]
        return native.build(root)
    assert not root.exists()
    data=scratch/'ventium-data-size.v2HaTO2X'
    parent,leaf=data/'parallel-next-tag-core-r1',data/'fp-compare-leaf-r1'
    old,built=native.load(parent/'build-started.json'),native.load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    assert native.sha(data/'parallel-next-tag-regression-audit.json')==AUDIT
    audit=native.load(data/'parallel-next-tag-regression-audit.json')
    assert audit['audit_passed'] and audit['functional_passes']==108 and audit['cycle_traces_unchanged']==20
    assert not audit['canonical_gate_passed']
    assert native.sha(leaf/'closed.json')==LEAF
    checked,begun=native.load(leaf/'closed.json'),native.load(leaf/'started.json')
    assert checked['passed'] and checked['pins_unchanged'] and checked['error'] is None
    assert len(checked['rows'])==5 and all(r['build_exit']==0 and r['actual_wait'] and
        r['affinity_observed'] and r['native_exit']==(0 if r['name']=='positive' else 1) for r in checked['rows'])
    assert checked['rows'][0]['coverage']['checks']==425984
    owner=dict(line.split('=',1) for line in subprocess.check_output(['systemctl','--user','show',
        'ventium-fp-compare-leaf-oct14-r1.service','-pMainPID','-pSubState','-pExecMainStatus',
        '-pInvocationID'],text=True,timeout=5).splitlines())
    assert owner==dict(MainPID='0',SubState='exited',ExecMainStatus='0',
                      InvocationID='83dce66778da4010a29c13b9c0d665e9')
    source=parent/'candidate'; files=native.common.candidate_files(source)
    assert len(files)==195 and all(native.sha(p)==old['pins'][str(p)] for p in files)
    flags=[s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and '-GAXI_LINE_REPLAY=0' in flags[0]
    assert 'VL_J=32' in old['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0])
    assert len(set(definitions))==len(definitions)==152 and definitions==begun['definitions']
    changed=recipe.transform((source/FILE).read_text())
    assert changed==(leaf/'proposal.sv').read_text()
    pins=dict(old['pins']);pins.update(begun['pins'])
    for row in checked['rows']:pins.update(row['artifacts'])
    for p in (Path(__file__),Path(recipe.__file__),Path(native.__file__),Path(native.common.__file__),
              REPO/'verif/l1/build_window_current_core.py',HERE/'test_prepare.py',
              leaf/'started.json',leaf/'closed.json',data/'parallel-next-tag-regression-audit.json',
              parent/'build-started.json',parent/'build-closed.json',parent/'obj/tb_ventium'):
        pins[str(p.resolve())]=native.sha(p)
    assert native.stable(pins)
    root.mkdir();shutil.copytree(source,root/'candidate');(root/'candidate'/FILE).write_text(changed)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert [n for n in names if native.sha(source/n)!=native.sha(root/'candidate'/n)]==[FILE]
    host=root/('tb_fp_compare_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=[FILE],compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None))
    print('FP compare classifier prepared; no compiler or FPGA launch.')
    return 0


if __name__=='__main__':raise SystemExit(main())
