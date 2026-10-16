"""Transfer the nine-file ACK cut into the exact retained-input full PC.

All other processor/peripheral bytes, 157 defines, posted-16 transport, native
input host and full P5 caches remain unchanged. Existing canonical failures
remain failures; this diagnostic build does not qualify guests or hardware.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_raw_prime_storage_soc as previous

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'verif/l1'))
import prepare_system_read_ack as recipe
import build_system_read_ack_core as core_build
import audit_system_read_ack_core as core_audit

ROOT=previous.ROOT
PARENT=ROOT/'raw-prime-storage-soc-r1'
CORE=ROOT/'system-read-ack-core-r1'
PARENT_MODEL='e9159acb28b80a9511a87cfca1872ab907f43eb3e6f2956dc1a3d3150bcd0fd7'
CORE_MODEL=core_audit.run.MODEL
CHANGES=core_build.CHANGES
transfer=previous.transfer
sha,load,save,stable=previous.sha,previous.load,previous.save,previous.stable
PS2=previous.parent_build.ui.PS2
PS2_SHA=previous.parent_build.ui.PS2_SHA


def check_delta(name,before,after):
    if name in CHANGES:
        assert recipe.transform(before.decode(),name.removeprefix(recipe.PREFIX)).encode()==after
        return True
    assert before==after,'unreviewed source delta: '+name
    return False


def evidence():
    # Re-run the independent closed-state/clock and ownership audit. Do not
    # trust a success flag without native records and source hashes.
    audit=core_audit.audit(ROOT)
    assert audit['directed_passed'] and audit['models']==dict(parent=core_build.MODEL,candidate=CORE_MODEL)
    assert audit['counts']==dict(cases=19,trace_pairs=114,functional_records=26667,
        cycle_records=26667,v_retirements=5925,native_children=228)
    assert not any(audit[k] for k in ('canonical_gate_passed','standard_suite','hardware_acceptance'))
    pins=dict(audit['pins'])
    canonical=ROOT/'system-read-ack-canonical-audit-r1.json'
    checked=load(canonical)
    assert checked['parent_identical'] and checked['same_input_parent_replay']
    assert checked['native_gate_exit']==2 and not checked['canonical_gate_passed']
    assert len(checked['rows'])==128 and all(r['same_records'] for r in checked['rows'])
    assert sum(r['records'] for r in checked['rows'] if r['mode']=='func')==80800
    pins.update(checked['pins']);pins[str(canonical)]=sha(canonical)
    for folder in (ROOT/'raw-prime-storage-input-r1',PARENT/'coremark-ui-disabled-r1'):
        accepted=load(folder/'audit.json')
        assert accepted['passed'] and accepted['model']==PARENT_MODEL and not accepted['standard_suite']
        pins.update(accepted.get('artifacts',{}));pins.update(accepted.get('artifact_pins',{}))
        pins[str(folder/'audit.json')]=sha(folder/'audit.json')
    assert stable(pins)
    return pins


def prepare(root):
    assert root.parent==ROOT and not root.exists()
    before,done=[load(PARENT/n) for n in ('build-started.json','build-closed.json')]
    assert done['passed'] and done['inputs_unchanged'] and done['native_exit']==0
    assert sha(PARENT/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==done['binary_sha256']==PARENT_MODEL
    assert before['directed_model']==core_build.MODEL and before['binding_read_wire']=='kb_fifo_rdreq'
    assert before['changes']==[previous.recipe.FILE] and before['inherited_cycle_cost']['diagnostic_only']
    start,built=[load(CORE/n) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(CORE/'obj/tb_ventium')==built['binary_sha256']==CORE_MODEL
    assert start['parent_model']==core_build.MODEL and start['changes']==CHANGES
    assert stable(start['pins']) and stable(before['pins'])
    pins=evidence()
    source=PARENT/'source';files=sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p)==before['pins'][str(p)] for p in files)
    shared=before['intersecting_rtl_sources'];assert len(shared)==102
    assert sorted(n for n in shared if check_delta(n,(source/n).read_bytes(),
        (CORE/'candidate'/n).read_bytes()))==CHANGES
    assert sha(source/PS2)==PS2_SHA
    root.mkdir();shutil.copytree(source,root/'source')
    for name in CHANGES:shutil.copyfile(CORE/'candidate'/name,root/'source'/name)
    assert sorted(str(p.relative_to(source)) for p in files if check_delta(str(p.relative_to(source)),
        p.read_bytes(),(root/'source'/p.relative_to(source)).read_bytes()))==CHANGES
    assert all(sha(root/'source'/n)==sha(CORE/'candidate'/n) for n in shared)
    old_host=Path(before['host'])
    host=root/'source/ao486-sim/ven'/('sim_system_read_ack_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(old_host,host)
    command=[s.replace(str(PARENT),str(root)) for s in before['command']]
    old_arg=str(root/old_host.relative_to(PARENT));assert command.count(old_arg)==1
    command=[str(host) if s==old_arg else s for s in command]
    transfer.check_definitions(command,(PARENT/'defines.txt').read_text().splitlines())
    shutil.copyfile(PARENT/'defines.txt',root/'defines.txt')
    pins.update(before['pins']);pins.update(start['pins'])
    for p in (Path(__file__),Path(recipe.__file__),Path(core_build.__file__),Path(core_audit.__file__),
              Path(previous.__file__),Path(transfer.__file__),Path(transfer.base.__file__),
              root/'defines.txt',PARENT/'build-started.json',PARENT/'build-closed.json',PARENT/'build.log',
              PARENT/'obj1-speed-q16-parentpolicy/ao486sim_board_posted',CORE/'build-started.json',
              CORE/'build-closed.json',CORE/'obj/tb_ventium',*(p for p in (root/'source').rglob('*') if p.is_file())):
        pins[str(p)]=sha(p)
    assert stable(pins)
    save(root/'prepared.json',dict(command=command,pins=pins,changes=CHANGES,added_defines=[],
        parent=str(PARENT),parent_model=PARENT_MODEL,directed_core=str(CORE),directed_model=CORE_MODEL,
        host=str(host),intersecting_rtl_sources=shared,processor_rtl_changes=CHANGES,
        controller_sha256=PS2_SHA,binding_read_wire='kb_fifo_rdreq',host_headers=before['host_headers'],
        inherited_cycle_cost=before['inherited_cycle_cost'],input_parent=before['input_parent'],
        input_parent_model=before['input_parent_model'],legacy_aggregate_gate_passed=False,
        canonical_gate_passed=False,qualification='UNQUALIFIED',standard_suite=False,
        hardware_acceptance=False,gameplay_ipc=None,note='System read ACK only; full parent state/clock equality.'))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();root=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.parent==ROOT and Path(os.environ['TMPDIR']).resolve()==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    if a.action=='prepare':
        prepare(root);print('System-read full PC prepared; compiler not launched.',flush=True);return 0
    return transfer.base.build(root)


if __name__=='__main__':raise SystemExit(main())
