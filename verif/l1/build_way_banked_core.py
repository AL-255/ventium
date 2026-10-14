"""Compose verified way-banked tags and rebased fetch-fault arithmetic.

Two source files only; preserve the full 195-file closure, 152 definitions,
UV/system/relocated fast paths, single-fill policy and native build guards.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import prepare_way_banked_tags as tags
from build_window_current_core import native

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/issue_uv'))
import prepare_fetch_fault_page_current as fetch

MODEL='5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8'
CHANGES=['rtl/core/core.sv','rtl/mem/ven_l1d.sv']


def changed_sources(source):
    return {'rtl/core/core.sv':fetch.transform((source/'rtl/core/core.sv').read_text()),
            'rtl/mem/ven_l1d.sv':tags.transform((source/'rtl/mem/ven_l1d.sv').read_text())}


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    data=scratch/'ventium-data-size.v2HaTO2X'
    assert __debug__ and root==data/'way-banked-core-r1'
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    assert native.sha(native.__file__)=='9654b012be8e49f6cdd7d3ea0cd7191684febb107cd461cd99469f8dce5899c2'
    if args.action=='build':
        assert os.sched_getaffinity(0)==set(range(32))-{10,11}
        assert Path('/proc/self/cgroup').read_text().strip().endswith('/ventium-ipc-parallel32.scope')
        subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
        assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
        subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
            'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
        native.MODEL=MODEL
        native.CHANGES=CHANGES
        return native.build(root)
    assert not root.exists()
    parent=data/'fp-compare-core-r1'
    cache=data/'way-banked-tag-cache-r1'
    probe=data/'way-banked-tag-probe-r1'
    leaf=scratch/'ventium-fetch-fault-page-leaf.wkkmde3g'
    old,built=native.load(parent/'build-started.json'),native.load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert native.sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    assert native.sha(data/'fp-compare-regression-audit.json')=='20ec2c93635ad2548b1977e30065e64f910a3630f545385e9fcc2e48bdf36732'
    regress=native.load(data/'fp-compare-regression-audit.json')
    assert regress['audit_passed'] and regress['functional_passes']==108 and regress['cycle_traces_unchanged']==20
    assert not regress['canonical_gate_passed']
    checked=native.load(cache/'audit.json')
    inferred=native.load(probe/'audit.json')
    assert native.sha(cache/'audit.json')=='0674db78c180bf6901d2c91b2b164b1bdf789d774cce351644345fd035c67b86'
    assert native.sha(probe/'audit.json')=='8c83d47cbee84baa1fc9b578743f30df04ed6a2c005e57cf3c94423e6f3036af'
    assert checked['passed'] and checked['samples']==747037 and checked['rejected_mutations']==2
    assert inferred['passed'] and inferred['profiles']['candidate']['tag_ff']==0
    assert inferred['profiles']['parent']['tag_ff']==5120
    leaf_data=native.load(leaf/'evidence.json')
    assert leaf_data['invocation']=='8096281e69e44fd7b68677cbf9cd5c74'
    leaf_owner=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',
        'ventium-fetch-page-current-oct14-r1.service','-p','InvocationID','-p','MainPID',
        '-p','SubState','-p','ExecMainStatus'],text=True).splitlines())
    assert leaf_owner==dict(InvocationID=leaf_data['invocation'],MainPID='0',SubState='exited',ExecMainStatus='0')
    expected={'page-identity':'unsat','cross-identity':'unsat','missing-underflow-mutant':'sat',
              'wrong-boundary-mutant':'sat','narrow-carry-mutant':'sat'}
    assert len(leaf_data['commands'])==11
    for row in leaf_data['commands']:
        name=row['name']
        assert row['actual_wait']
        assert row['native_exit']==(1 if name in ('wrong-boundary-run','missing-underflow-run') else 0)
        assert native.sha(leaf/(name+'.stdout'))==row['stdout_sha256']
        assert native.sha(leaf/(name+'.stderr'))==row['stderr_sha256']
        if name in expected:
            assert (leaf/(name+'.stdout')).read_text().strip()==expected[name]
    assert 'FETCH-FAULT-PAGE-OK combinations=1048576' in (leaf/'candidate-run.stdout').read_text()
    source=parent/'candidate'
    files=native.common.candidate_files(source)
    assert len(files)==195 and all(native.sha(p)==old['pins'][str(p)] for p in files)
    flags=[s for s in old['command'] if s.startswith('VL_EXTRA_DEFINES=')]
    assert len(flags)==1 and '--assert' in flags[0] and '-GAXI_LINE_REPLAY=0' in flags[0]
    assert 'VL_J=32' in old['command']
    definitions=re.findall(r'\+define\+(\w+)',flags[0])
    assert len(definitions)==len(set(definitions))==152
    changes=changed_sources(source)
    assert changes['rtl/mem/ven_l1d.sv']==(cache/'positive/ven_l1d.sv').read_text()
    assert fetch.NEW in (leaf/'candidate.sv').read_text()
    pins=dict(old['pins'])
    pins.update(checked['pins'])
    pins.update(inferred['pins'])
    pins.update(leaf_data['pins'])
    dependencies=[Path(__file__),Path(tags.__file__),Path(fetch.__file__),Path(fetch.original.__file__),
        Path(native.__file__),Path(native.common.__file__), REPO/'verif/l1/build_window_current_core.py',
        REPO/'verif/issue_uv/test_fetch_fault_page_current.py',REPO/'verif/issue_uv/test_fetch_fault_page.py',
        cache/'audit.json',probe/'audit.json',data/'fp-compare-regression-audit.json',
        parent/'obj/tb_ventium',parent/'build-started.json',parent/'build-closed.json',*leaf.iterdir()]
    for p in dependencies:
        assert p.is_file() and not p.is_symlink()
        pins[str(p.resolve())]=native.sha(p)
    assert native.stable(pins)
    root.mkdir()
    shutil.copytree(source,root/'candidate')
    for name,text in changes.items():
        (root/'candidate'/name).write_text(text)
    names=[str(p.relative_to(source)) for p in files]
    assert [str(p.relative_to(root/'candidate')) for p in native.common.candidate_files(root/'candidate')]==names
    assert sorted(n for n in names if native.sha(source/n)!=native.sha(root/'candidate'/n))==CHANGES
    host=root/('tb_way_banked_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old['host'],host)
    command=native.common.relocate(old['command'],parent,root,Path(old['host']),host)
    pins[str(host)]=native.sha(host)
    pins.update({str(root/'candidate'/n):native.sha(root/'candidate'/n) for n in names})
    native.save(root/'prepared.json',dict(pins=pins,command=command,host=str(host),parent=str(parent),
        parent_model=MODEL,definitions=definitions,changes=CHANGES,compiler_started=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None))
    print('WAY-BANKED-CORE-PREPARED '+str(root),flush=True)
    return 0


if __name__=='__main__':
    raise SystemExit(main())
