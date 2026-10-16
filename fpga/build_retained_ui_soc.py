"""Private whole-PC link of current-AUX retained RX and ordinary pin input.

The V-result CPU, all defines and the live parents remain untouched. This is
integration diagnosis, not Win95/UI/FPGA acceptance. The original low-clock
mouse timeout failure remains recorded; the extended bound is diagnostic only.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_v_result_carry_soc as parent_builder

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'verif/ps2_ui'))
import prepare_pc_live_input as host_recipe
import prepare_loss_aux as controller_recipe

base=parent_builder.base
sha,load,save,stable=base.sha,base.load,base.save,base.stable
PARENT_MODEL='b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'
PS2=parent_builder.AUX
PS2_SHA='9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405'
HEADERS=('ui_input_host.h','pc_keyboard_input.h','pc_keyboard_retained.h')


def transform_host(text):
    result=host_recipe.transform(text)
    for old,new in (('#include "pc_keyboard_input.h"','#include "pc_keyboard_retained.h"'),
                    ('ven_ui::pc_keyboard_before(','ven_ui::pc_keyboard_retained_before('),
                    ('ven_ui::pc_keyboard_after(','ven_ui::pc_keyboard_retained_after(')):
        result=host_recipe.once(result,old,new)
    return result


def evidence(proof):
    pins={}
    for name in ('ps2-loss-aux-iobus-r1','ps2-loss-aux-transport-r1','retained-host-r1','retained-rtl-r1'):
        root=proof/name;start,done=load(root/'started.json'),load(root/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert not any(done['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
        pins.update(start['pins'])
        if name=='ps2-loss-aux-iobus-r1':
            assert len(done['rows'])==32 and all(r['passed'] for r in done['rows'])
            assert sum(r['label']=='candidate' and r['native_exit']==0 for r in done['rows'])==16
            assert sum(r['label']=='parent' and r['native_exit']==1 for r in done['rows'])==16
        if name=='ps2-loss-aux-transport-r1':
            assert not done['original_run_passed'] and len(done['rows'])==4
            assert all(r['passed'] and r['native_exit']==0 for r in done['rows'])
        if name=='retained-host-r1':
            assert len(done['rows'])==3 and all(r['compile_exit']==r['native_exit']==0 for r in done['rows'])
        if name=='retained-rtl-r1':
            assert done['build_exit']==done['native_exit']==0
            assert 'UI-RETAINED-RTL-OK ordinary=8 retained=4 collisions=2 flush_refusals=4 full_pc=0' in (root/'native.log').read_text()
        for row in done.get('rows',[]):
            if 'log' in row:pins[str(Path(row['log']).resolve())]=row.get('log_sha256',row.get('sha256'))
            pins.update(row.get('logs',{}))
        pins.update(done.get('artifacts',{}))
        for path in (root/'started.json',root/'closed.json'):pins[str(path)]=sha(path)
    # Do not silently waive the old first-command deadline failure.
    root=proof/'ps2-loss-aux-extended-r2';done=load(root/'closed.json')
    assert not done['passed'] and done['pins_unchanged']
    assert done['errors']==['candidate-transport-autoack0','candidate-transport-autoack1']
    pins.update(load(root/'started.json')['pins'])
    for row in done['rows']:pins[str(Path(row['log']).resolve())]=row['log_sha256']
    for path in (root/'started.json',root/'closed.json'):pins[str(path)]=sha(path)
    assert stable(pins)
    return pins


def prepare(parent,proof,root):
    assert not root.exists() and not root.is_relative_to(parent) and not parent.is_relative_to(root)
    assert parent==host_recipe.PARENT.resolve(strict=True)
    before,closed=load(parent/'build-started.json'),load(parent/'build-closed.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==closed['binary_sha256']==PARENT_MODEL
    source=parent/'source';files=sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p)==before['pins'][str(p)] for p in files)
    assert sha(parent/host_recipe.MAIN)==host_recipe.MAIN_SHA
    assert sha(source/PS2)==host_recipe.PS2_SHA
    assert sha(host_recipe.HERE/'ui_input_host.h')==host_recipe.INPUT_SHA
    pins=evidence(proof);pins.update(before['pins'])
    changed=controller_recipe.transform((source/PS2).read_text())
    assert hashlib.sha256(changed.encode()).hexdigest()==PS2_SHA
    host_text=transform_host((parent/host_recipe.MAIN).read_text())
    root.mkdir();shutil.copytree(source,root/'source')
    (root/'source'/PS2).write_text(changed)
    assert [str(p.relative_to(source)) for p in files
        if sha(p)!=sha(root/'source'/p.relative_to(source))]==[PS2]
    host=root/'source/ao486-sim/ven'/('sim_retained_ui_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    with host.open('x') as f:f.write(host_text)
    for name in HEADERS:
        destination=host.parent/name
        assert not destination.exists();shutil.copyfile(host_recipe.HERE/name,destination)
    command=[s.replace(str(parent),str(root)) for s in before['command']]
    old_host=root/host_recipe.MAIN
    assert command.count(str(old_host))==1
    command=[str(host) if s==str(old_host) else s for s in command]
    parent_builder.check_definitions(command,(parent/'defines.txt').read_text().splitlines())
    shutil.copyfile(parent/'defines.txt',root/'defines.txt')
    for p in (Path(__file__),Path(parent_builder.__file__),Path(base.__file__),Path(base.common.__file__),
              Path(host_recipe.__file__),Path(controller_recipe.__file__),
              *(host_recipe.HERE/n for n in HEADERS),
              *(host_recipe.HERE/'proposals'/n for n in controller_recipe.PATCHES),
              parent/'build-started.json',parent/'build-closed.json',parent/'build.log',
              parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted',root/'defines.txt',
              *(p for p in (root/'source').rglob('*') if p.is_file())):
        pins[str(p.resolve())]=sha(p)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,parent=str(parent),parent_model=PARENT_MODEL,
        directed_core=before['directed_core'],directed_model=before['directed_model'],
        changes=[PS2],processor_rtl_changes=[],added_defines=[],host=str(host),
        intersecting_rtl_sources=before['intersecting_rtl_sources'],controller_sha256=PS2_SHA,
        host_headers=list(HEADERS),ordinary_ps2_timing=True,legacy_input_excluded_with_fifo=True,
        original_transport_gate_passed=False,full_pc_input_qualified=False,
        canonical_gate_passed=False,qualification='UNQUALIFIED',standard_suite=False,
        hardware_acceptance=False,gameplay_ipc=None,mouse_motion=False,
        note='Private integration diagnostic only. All processor sources unchanged; explicit retained input contract. No snapshot, replay or guest-specific handling.'))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    for n in ('parent','proof'):ap.add_argument('--'+n,type=Path)
    ap.add_argument('--out',type=Path,required=True);a=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True);root=a.out.resolve()
    assert __debug__ and root!=scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    if a.action=='prepare':
        prepare(a.parent.resolve(strict=True),a.proof.resolve(strict=True),root)
        print('Retained-input PC prepared; no build/run launched.');return 0
    return base.build(root)


if __name__=='__main__':raise SystemExit(main())
