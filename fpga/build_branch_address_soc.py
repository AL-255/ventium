"""Source-audited PC transfer of early address shape and three FPREM repairs.

Retain the prefix-payload timing parent, not rejected fetch metadata. This
private build is unqualified: canonical and physical acceptance stay separate.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_payload_current_soc as base
REPO=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(REPO/'verif/l1'),str(REPO/'verif/srt')]
import prepare_branch_address_shape as recipe
import prepare_remainder_exact as numeric
import prepare_remainder_exceptions as exceptions
import prepare_remainder_underflow_core as underflow

sha,load,save,stable=base.sha,base.load,base.save,base.stable
PARENT_MODEL='5eee4d74d729663ad6af4abaa3f0fdbd5cc59937a36945ca81ff46e33b891ce9'
CORE_MODEL='6deb3e92ae302d2166c18d239711754c049f1f775f2518a2f5b576108eb8b16d'
BUILDER='9951c6768f0441d63a0dec66ad6b302afb019924fce529c9d034b1e41c01c8a3'
CHANGES=sorted([recipe.FILE,*underflow.PARENTS])


def transform(name,text):
    if name==recipe.FILE:return recipe.transform(text)
    if name=='rtl/core/core.sv':return underflow.transform(text,name)
    if name=='rtl/fpu/fpu_srt_div.sv':
        return underflow.transform(exceptions.transform(numeric.transform(text),name),name)
    if name=='fp_shared/ven_fp_top.sv':return underflow.transform(exceptions.transform(text,name),name)
    raise ValueError('unreviewed source delta: '+name)


def prepare(parent,core,proof,root):
    assert not root.exists() and sha(base.__file__)==BUILDER
    assert core==proof/'branch-address-core-r1'
    pins={}; statistics={}
    for name in ('branch-address-leaf-r1','branch-address-system-r1',
                 'branch-address-controls-r1','branch-address-func-r1',
                 'sequences-underflow-r1','cold-underflow-r1','partial-underflow-r1'):
        folder=proof/name; checked=load(folder/'closed.json'); before=load(folder/'started.json')
        assert checked['passed'] and checked['pins_unchanged'] and not checked.get('errors')
        assert stable(before['pins']);pins.update(before['pins'])
        for p in (folder/'started.json',folder/'closed.json'):pins[str(p)]=sha(p)
        if name=='branch-address-system-r1':
            assert len(checked['measurements'])==560 and checked['all_children_reaped']
            assert before['models']['candidate']==str(core/'obj/tb_ventium')
            statistics['branch_records']=sum(r['records'] for r in checked['measurements'] if r['model']=='candidate')
            assert statistics['branch_records']==77420
        if name=='branch-address-func-r1':
            assert len(checked['rows'])==108 and all(r['passed'] for r in checked['rows'])
            statistics['private_functional_passes']=108
    before,built=load(core/'build-started.json'),load(core/'build-closed.json')
    assert built['passed'] and built['native_exit']==0 and built['pins_unchanged']
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']==CORE_MODEL
    assert stable(before['pins']);pins.update(before['pins'])
    gate=load(core/'verify-closed.json')
    assert gate['pins_unchanged'] and not gate['masks_or_goldens_or_bands_changed']
    assert len(gate['deltas'])==20 and all(r['same_records'] for r in gate['deltas'])
    assert gate['canonical_gate_native_exit']==2 and not gate['canonical_gate_passed']
    old,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged']
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']==PARENT_MODEL
    source=parent/'source';files=sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p)==old['pins'][str(p)] for p in files)
    shared=[str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl','fp_shared')
            and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared)==102
    assert [n for n in shared if sha(source/n)!=sha(core/'candidate'/n)]==CHANGES
    for n in CHANGES:assert transform(n,(source/n).read_text())==(core/'candidate'/n).read_text()
    assert 'u_fetch_metadata' not in (core/'candidate/rtl/core/core.sv').read_text()
    hosts=[Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1 and stable(pins)
    root.mkdir();shutil.copytree(source,root/'source')
    for n in CHANGES:shutil.copyfile(core/'candidate'/n,root/'source'/n)
    assert all(sha(root/'source'/n)==sha(core/'candidate'/n) for n in shared)
    host=root/'source/ao486-sim/ven'/('sim_branch_address_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0],host)
    command=[s.replace(str(parent),str(root)) for s in old['command']]
    command=[str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]
    assert command[:2]==[str(REPO/'tools/build_scope.sh'),'--'] and '600s' in command
    affinity=command.index('taskset');assert command[affinity+1:affinity+3]==['-c','0-9,12-31']
    defs=[s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs)==len(set(defs))==156 and set(defs)==set((parent/'defines.txt').read_text().splitlines())
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    assert "localparam bit AO486_LINE_REPLAY = 1'b0;" in (root/'source/ao486-sim/ven/ven_ao486_shim.sv').read_text()
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dependency=parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dependency.read_text().replace('\\\n',' ').split()[1:]:
        p=Path(name)
        if p.is_absolute():pins[str(p)]=sha(p)
    for p in (*files,*(p for p in (root/'source').rglob('*') if p.is_file()),Path(__file__),
              Path(recipe.__file__),Path(numeric.__file__),Path(exceptions.__file__),
              Path(underflow.__file__),Path(underflow.leaf.__file__),Path(base.__file__),
              Path(base.common.__file__),root/'defines.txt',parent/'build-started.json',
              parent/'build-closed.json',parent/'build.log',core/'build-started.json',
              core/'build-closed.json',core/'verify-closed.json',core/'obj/tb_ventium'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,changes=CHANGES,added_defines=[],
        parent=str(parent),directed_core=str(core),host=str(host),intersecting_rtl_sources=shared,
        parent_model=PARENT_MODEL,directed_model=CORE_MODEL,statistics=statistics,
        canonical_gate_passed=False,qualification='UNQUALIFIED',gameplay_ipc=None,
        rejected_metadata_inherited=False,
        included_fixes=['early raw branch address','FPREM numeric/subnormal','FPREM operand exceptions','FPREM exact underflow']))


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('action',choices=('prepare','build'))
    for n in ('parent','core','proof'):ap.add_argument('--'+n,type=Path)
    ap.add_argument('--out',type=Path,required=True);a=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True);root=a.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3 and sha(base.__file__)==BUILDER
    if a.action=='prepare':
        assert a.parent and a.core and a.proof
        prepare(a.parent.resolve(strict=True),a.core.resolve(strict=True),a.proof.resolve(strict=True),root)
        print('Four-file transfer prepared; no compiler or FPGA acceptance.',flush=True);return 0
    return base.build(root)


if __name__=='__main__':raise SystemExit(main())
