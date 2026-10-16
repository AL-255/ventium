"""Transfer the tested early backing direction onto the V-result/AUX PC.

This changes one frozen RTL file, not the live guest's inputs. The full source
intersection and exact UV-fast/posted-16 profile are checked before compiling.
Canonical failure remains a failure; no standard-suite qualification is implied.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_v_result_carry_soc as previous

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'verif/l1'))
import prepare_backing_direction as recipe
import build_backing_direction_core as directed

base=previous.base
sha,load,save,stable=base.sha,base.load,base.save,base.stable
PARENT_MODEL='b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'
CORE_MODEL='e6194aa6b3f98cb7ef4cdb955377989ac45c441bde843021b535358c61e16993'
FILE='rtl/mem/ven_l1d.sv'
CHANGES=[FILE]
check_definitions=previous.check_definitions


def check_delta(name,before,after):
    if name==FILE:
        assert recipe.transform(before.decode()).encode()==after
        return True
    assert before==after,'unreviewed source change: '+name
    return False


def evidence(proof,core):
    pins=directed.check_leaf(proof/'backing-direction-leaf-r1')
    mixed=proof/'backing-direction-mixed-r1'
    start,done=load(mixed/'started.json'),load(mixed/'closed.json')
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert len(done['measurements'])==144 and start['pins'][str(core/'obj/tb_ventium')]==CORE_MODEL
    assert (done['memory_v_retirements'],done['wait_held'],done['wait_paired'])==(240,1140,312)
    pins.update(start['pins'])
    matched=proof/'backing-direction-matched-r1'
    before,closed=load(matched/'started.json'),load(matched/'closed.json')
    assert closed['regression_check_passed'] and closed['pins_unchanged'] and not closed['errors']
    assert not closed['masks_or_record_normalization'] and len(closed['rows'])==108
    assert sum(r['records'] for r in closed['rows'])==80800
    assert all(r['same_records'] and r['native']['actual_return_code']==0
               and r['native']['group_closed'] and not r['native']['timed_out'] for r in closed['rows'])
    pins.update(before['pins'])
    for r in closed['rows']:
        path=matched/r['name']/'parent.vtrace'
        assert sha(path)==r['trace_sha256'];pins[str(path)]=r['trace_sha256']
    gate=load(core/'verify-closed.json')
    assert not gate['canonical_gate_passed'] and gate['canonical_gate_native_exit']==2
    assert gate['pins_unchanged'] and not gate['masks_or_goldens_or_bands_changed']
    assert len(gate['deltas'])==20 and all(r['same_records'] for r in gate['deltas'])
    for p in (mixed/'started.json',mixed/'closed.json',matched/'started.json',matched/'closed.json',
              core/'verify-closed.json',proof/'backing-direction-canonical-inventory-r1.json'):
        pins[str(p)]=sha(p)
    assert stable(pins)
    return pins


def prepare(parent,core,proof,root):
    assert not root.exists()
    for source in (parent,core,REPO):
        assert not root.is_relative_to(source) and not source.is_relative_to(root)
    old,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']==PARENT_MODEL
    assert old['directed_model']==previous.CORE_MODEL and old['changes']==previous.CHANGES
    built,start=load(core/'build-closed.json'),load(core/'build-started.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']==CORE_MODEL
    assert start['parent_model']==previous.CORE_MODEL and start['changes']==CHANGES
    pins=evidence(proof,core)
    source=parent/'source';files=sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p)==old['pins'][str(p)] for p in files)
    shared=sorted(str(p.relative_to(source)) for p in files
        if p.relative_to(source).parts[0] in ('rtl','fp_shared')
        and (core/'candidate'/p.relative_to(source)).is_file())
    assert len(shared)==102 and set(shared)==set(old['intersecting_rtl_sources'])
    assert [n for n in shared if check_delta(n,(source/n).read_bytes(),(core/'candidate'/n).read_bytes())]==CHANGES
    assert sha(source/previous.AUX)==previous.AUX_SHA
    hosts=[Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts)==1
    root.mkdir();shutil.copytree(source,root/'source')
    shutil.copyfile(core/'candidate'/FILE,root/'source'/FILE)
    assert sorted(str(p.relative_to(source)) for p in files if check_delta(str(p.relative_to(source)),
        p.read_bytes(),(root/'source'/p.relative_to(source)).read_bytes()))==CHANGES
    host=root/'source/ao486-sim/ven'/('sim_backing_direction_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0],host)
    command=[s.replace(str(parent),str(root)) for s in old['command']]
    command=[str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    check_definitions(command,(parent/'defines.txt').read_text().splitlines())
    shutil.copyfile(parent/'defines.txt',root/'defines.txt')
    pins.update(old['pins']);pins.update(start['pins'])
    for p in (Path(__file__),Path(recipe.__file__),Path(directed.__file__),Path(previous.__file__),
              Path(base.__file__),Path(base.common.__file__),root/'defines.txt',
              parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
              parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted',core/'build-started.json',
              core/'build-closed.json',core/'obj/tb_ventium',
              *(p for p in (root/'source').rglob('*') if p.is_file())):
        pins[str(p)]=sha(p)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,changes=CHANGES,added_defines=[],
        parent=str(parent),parent_model=PARENT_MODEL,directed_core=str(core),directed_model=CORE_MODEL,
        host=str(host),intersecting_rtl_sources=shared,aux_sha256=previous.AUX_SHA,
        canonical_gate_passed=False,qualification='UNQUALIFIED',standard_suite=False,
        hardware_acceptance=False,gameplay_ipc=None,
        note='Only inactive backing direction becomes early. Active packets, admission, cycles and all processor/peripheral source closure retained.'))


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
        print('Backing-direction PC transfer prepared; compiler not launched.',flush=True);return 0
    return base.build(root)


if __name__=='__main__':raise SystemExit(main())
