"""Transfer the tested V-result carry cut onto the current AUX-corrected PC.

The two exact core deltas, 157 defines and every other processor/peripheral
source are preserved. Compilation does not qualify timing, guests or hardware.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_payload_current_soc as base

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'verif/issue_uv'))
import prepare_v_result_carry as recipe
import run_v_result_carry_leaf as leaf

PARENT_MODEL='70c8de9eb55fda79b9fe359553ebd0b73de1e865c61414773000354edaff7b57'
CORE_MODEL='a8e5d55b7704f2449002c71af8db1c5c2fe7ae908669fc5dbf2e663d3a59ff73'
AUX='3rd-party/ao486_MiSTer/rtl/soc/ps2.v'
AUX_SHA='2ee3b64fc24875b3aaca0e6296a2514161f19cef5e6f79aa90923ca06f1846da'
CHANGES=sorted(recipe.HASHES)
sha,load,save,stable=base.sha,base.load,base.save,base.stable


def check_delta(name,before,after):
    if name in CHANGES:
        assert recipe.transform(before.decode(),name).encode()==after
        return True
    assert before==after, 'unreviewed source change: '+name
    return False


def check_definitions(command,expected):
    defs=[s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs)==len(set(defs))==157 and set(defs)==set(expected)
    assert {'VEN_FE_PIPE','VEN_L1_AXI','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_X87_MF_STRICT',
            'VEN_KBC_FAST','VEN_KBD_AUTOACK'}<=set(defs)
    assert not {'SYNTHESIS','VTM_NO_DPI','VEN_P54_REGMEM_PRIME'}&set(defs)
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    return defs


def evidence(proof,core):
    pins=leaf.check_receipt(proof/'v-result-carry-leaf-r3')
    for name,count in (('system',576),('mixed',144),('integer',1024),('fp',1536),('boundary',88)):
        root=proof/('v-result-carry-'+name+'-r1')
        before,done=load(root/'started.json'),load(root/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert len(done['rows' if name=='boundary' else 'measurements'])==count
        assert before['pins'][str(core/'obj/tb_ventium')]==CORE_MODEL and stable(before['pins'])
        if name=='system':assert done['subject_v_retirements']>0
        if name=='mixed':assert all(done[k]>0 for k in ('memory_v_retirements','wait_held','wait_paired'))
        if name=='integer':assert done['all_children_reaped'] and all(r['saved_clocks']==0 for r in done['deltas'])
        pins.update(before['pins'])
        for p in (root/'started.json',root/'closed.json'):pins[str(p)]=sha(p)
    root=proof/'v-result-carry-held-r1';before,done=load(root/'inputs.json'),load(root/'result.json')
    assert done['passed'] and done['inputs_unchanged'] and not done['errors'] and len(done['cases'])==48
    assert before[str(core/'obj/tb_ventium')]==CORE_MODEL and stable(before)
    for row in done['cases']:
        assert row['measurements']['candidate']==row['measurements']['control']
        assert row['pair_preserved'] and row['gain_fraction']==0
        if row['kind']==5:assert row['measurements']['candidate']['held_primes']>=12
    pins.update(before)
    for p in (root/'inputs.json',root/'result.json'):pins[str(p)]=sha(p)
    return pins


def prepare(parent,core,proof,root):
    assert not root.exists()
    for source in (parent,core,proof,REPO):
        # The output may be a sibling of the evidence runs, not inside a source.
        if source!=proof:assert not root.is_relative_to(source) and not source.is_relative_to(root)
    old,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged']
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']==PARENT_MODEL
    assert old['directed_model']==leaf.MODEL and old['parent_profile']=='pipe-wait'
    built,started=load(core/'build-closed.json'),load(core/'build-started.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']==CORE_MODEL
    assert started['parent_model']==leaf.MODEL and started['changes']==CHANGES and stable(started['pins'])
    pins=evidence(proof,core)
    source=parent/'source';files=sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p)==old['pins'][str(p)] for p in files) and sha(source/AUX)==AUX_SHA
    shared=old['intersecting_rtl_sources']
    assert len(shared)==102
    assert sorted(n for n in shared if check_delta(n,(source/n).read_bytes(),(core/'candidate'/n).read_bytes()))==CHANGES
    hosts=[Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1
    root.mkdir();shutil.copytree(source,root/'source')
    for name in CHANGES:shutil.copyfile(core/'candidate'/name,root/'source'/name)
    assert sorted(str(p.relative_to(source)) for p in files if check_delta(str(p.relative_to(source)),
        p.read_bytes(),(root/'source'/p.relative_to(source)).read_bytes()))==CHANGES
    host=root/'source/ao486-sim/ven'/('sim_v_result_carry_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0],host)
    command=[s.replace(str(parent),str(root)) for s in old['command']]
    command=[str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    check_definitions(command,(parent/'defines.txt').read_text().splitlines())
    shutil.copyfile(parent/'defines.txt',root/'defines.txt')
    pins.update(old['pins']);pins.update(started['pins'])
    for p in (Path(__file__),Path(recipe.__file__),Path(leaf.__file__),Path(base.__file__),Path(base.common.__file__),
              root/'defines.txt',parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
              parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted',core/'build-started.json',
              core/'build-closed.json',core/'obj/tb_ventium',*(p for p in (root/'source').rglob('*') if p.is_file())):
        pins[str(p)]=sha(p)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,changes=CHANGES,added_defines=[],
        parent=str(parent),parent_model=PARENT_MODEL,directed_core=str(core),directed_model=CORE_MODEL,
        host=str(host),intersecting_rtl_sources=shared,aux_sha256=AUX_SHA,canonical_gate_passed=False,
        qualification='UNQUALIFIED',standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,
        note='Only V arithmetic result loses carry input; original flag CF and all execution authority retained.'))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    for n in ('parent','core','proof'):ap.add_argument('--'+n,type=Path)
    ap.add_argument('--out',type=Path,required=True);a=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True);root=a.out.resolve()
    assert __debug__ and root!=scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    if a.action=='prepare':
        prepare(a.parent.resolve(strict=True),a.core.resolve(strict=True),a.proof.resolve(strict=True),root)
        print('V-result transfer prepared; compiler not launched.',flush=True);return 0
    return base.build(root)


if __name__=='__main__':raise SystemExit(main())
