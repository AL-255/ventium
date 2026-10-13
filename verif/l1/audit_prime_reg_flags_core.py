"""Audit closed core comparisons without promoting canonical failures to passes."""
import argparse
import json
from pathlib import Path
import re
import subprocess

import prepare_prime_reg_flags as recipe
from build_prime_reg_flags_core import sha,load,save,stable,common
from run_prime_reg_flags_core import PARENT,CANDIDATE
from run_prime_reg_flags_corners import fixture,PATTERN,FIELDS


def owner(unit,invocation,expected):
    state=dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',unit,'-p','InvocationID','-p','MainPID',
        '-p','ExecMainStatus'],text=True).splitlines())
    assert state==dict(InvocationID=invocation,MainPID='0',ExecMainStatus=str(expected))
    return dict(unit=unit,**state)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','candidate','ab','corners','replay','out'):
        ap.add_argument('--'+name,required=True,type=Path)
    args=ap.parse_args()
    parent,core,ab,corners,replay=[getattr(args,n).resolve(strict=True)
                                 for n in ('parent','candidate','ab','corners','replay')]
    pins={str(Path(__file__).resolve()):sha(__file__)}
    def read(root,name):
        path=root/name;pins[str(path)]=sha(path);return load(path)
    before=read(core,'build-started.json');built=read(core,'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']==CANDIDATE
    assert sha(parent/'obj/tb_ventium')==PARENT
    pins.update(before['pins'])
    for model in (core/'obj/tb_ventium',parent/'obj/tb_ventium'):pins[str(model)]=sha(model)
    files=common.candidate_files(core/'candidate')
    assert len(files)==195
    changed=[str(p.relative_to(core/'candidate')) for p in files
             if sha(p)!=sha(parent/'candidate'/p.relative_to(core/'candidate'))]
    assert changed==before['changes']==['rtl/core/core_mem_chain.svh']
    sources={n:(parent/'candidate/rtl/core'/n).read_text() for n in recipe.PARENTS}
    assert recipe.transform(sources)==(core/'candidate'/changed[0]).read_text()
    stamps=[]
    for folder in (parent,core):
        path=folder/'obj/Vventium_top__verFiles.dat';pins[str(path)]=sha(path)
        command=next(s for s in path.read_text().splitlines() if s.startswith('C '))
        assert ' --assert ' in command
        stamps.append(set(re.findall(r'\+define\+(\w+)',command)))
    assert stamps[0]==stamps[1]==set(before['definitions']) and len(stamps[1])==152
    started,done=read(ab,'started.json'),read(ab,'closed.json')
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert done['probe_runs']==4240
    assert done['coverage']==dict(clocks=21190336,agi=18172,ref=24352,retained=0,
        prime=282808,intent=5616,request=3072,accept=1872,shape_only=1536)
    assert [r['label'] for r in done['rows']]==['load-store','held','branch','integer','fp','agi','ref','agi-store']
    pins.update(started['pins'])
    for row in done['rows']:
        name='result.json' if row['label']=='held' else 'closed.json'
        path=ab/row['label']/name
        assert row['native_exit']==0 and sha(path)==row['receipt_sha256']
        checked=read(ab/row['label'],name)
        assert checked['passed'] and not checked['errors']
    start,closed=read(corners,'started.json'),read(corners,'closed.json')
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    pins.update(closed['pins'])
    assert len(closed['rows'])==3
    base=Path(__file__).resolve().parents[2]/'verif/fe_pipe/raw-branch-prime.S'
    for row in closed['rows']:
        name=row['variant']
        assert (corners/(name+'.S')).read_text()==fixture(base.read_text(),name)
        checked=read(corners/name,'closed.json')
        assert sha(corners/name/'closed.json')==row['checker_sha256']
        assert checked['passed'] and len(checked['measurements'])==24 and row['native_exit']==0
        counts={k:0 for k in FIELDS};runs=0
        for path in (corners/name).rglob('candidate*.stdout'):
            found=PATTERN.findall(path.read_text());assert len(found)==1
            counts={k:counts[k]+int(v) for k,v in zip(FIELDS,found[0])};runs+=1
        assert runs==row['runs']==24 and counts==row['counts']
        assert counts[{'shift':'shift','preserve':'preserve','alternating':'rejects'}[name]]>0
    verified=read(core,'verify-closed.json');verify_start=read(core,'verify-started.json')
    assert verified['pins_unchanged'] and not verified['masks_or_goldens_or_bands_changed']
    assert verified['canonical_gate_native_exit'] in (0,2)
    assert verified['controller_timed_out'] and verified['recovered_from_native_marker']
    assert (core/'verify-recovery/result').read_text()=='2\n'
    pins.update(verified['recovery_pins'])
    assert len(verified['deltas'])==20 and all(r['same_records'] for r in verified['deltas'])
    replay_start,replayed=read(replay,'started.json'),read(replay,'closed.json')
    assert replayed['same_input_regression_passed'] and replayed['pins_unchanged'] and not replayed['errors']
    assert len(replayed['rows'])==108 and replayed['records']==80800
    pins.update(replay_start['pins'])
    owners=[owner('ventium-prime-reg-core-oct13-r1.service','d2d0d66bf5e147f984807f2820b14fb7',0),
            owner('ventium-prime-reg-ab-oct13-r1.service','991725d02c494dd5ba359baf94625e28',0),
            owner('ventium-prime-reg-corners-oct13-r1.service',start['invocation'],0),
            owner('ventium-prime-reg-verify-oct13-r1.service',verify_start['invocation'],
                  0 if verified['canonical_gate_passed'] else 1),
            owner('ventium-prime-reg-replay-oct13-r2.service',replay_start['invocation'],0)]
    assert stable(pins)
    save(args.out.resolve(),dict(passed=True,pins=pins,owners=owners,model=CANDIDATE,parent=PARENT,
         changed_files=changed,probe_runs=4240,corner_runs=72,corner_counts=[r['counts'] for r in closed['rows']],
         canonical_gate_passed=verified['canonical_gate_passed'],canonical_native_exit=verified['canonical_gate_native_exit'],
         canonical_controller_timed_out=True,native_result_recovered_from_durable_marker=True,
         same_input_cases=108,same_input_records=80800,standard_suite=False,hardware_acceptance=False,
         timing_measured=False,gameplay_ipc=None))
    print('PRIME-REG-CORE-AUDIT-OK; canonical status retained separately',flush=True)


if __name__=='__main__':
    assert __debug__
    main()
