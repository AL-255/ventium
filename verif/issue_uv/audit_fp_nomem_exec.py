#!/usr/bin/env python3
"""Re-read closed native evidence; keep canonical failure separate from A/B proof."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/diff'))
import tracefmt


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def load(p):
    return json.loads(p.read_text())


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    args = ap.parse_args()
    root = args.root.resolve(strict=True)
    core = root/'core'
    pins = {}
    for p in (core/'build-started.json', core/'verify-started.json', root/'system/started.json',
              root/'system/matrix/started.json', root/'faults-r1/started.json'):
        pins.update(load(p)['pins']); pins[str(p)] = sha(p)
    pins.update(load(root/'leaf-r1/pins.json'))
    for p in (root/'agi-r1/started.json', root/'agi-r1/candidate/started.json',
              root/'agi-r1/rejected/started.json'):
        pins.update(load(p)['pins']); pins[str(p)] = sha(p)
    agi = load(root/'agi-r1/closed.json')
    assert agi['passed'] and agi['pins_unchanged'] and not agi['performance_policy_changed']
    assert [(r['native_exit'], r['expected_negative']) for r in agi['rows']] == [(0,False),(1,True)]
    assert agi['rows'][0]['control_agi_accepts'] == agi['rows'][0]['tested_agi_accepts'] > 0
    assert agi['rows'][1]['control_agi_accepts'] > 0 and agi['rows'][1]['tested_agi_accepts'] == 0
    rejected = load(root/'agi-r1/rejected/closed.json')
    assert not rejected['passed'] and rejected['pins_unchanged'] and rejected['all_children_reaped']
    failures = [r for r in rejected['errors'] if 'case' in r]
    assert len(failures) == 12 and all('entire cycle record lists differ' in r['error'] for r in failures)
    for label, control_count, tested_count in (
            ('candidate', agi['rows'][0]['control_agi_accepts'], agi['rows'][0]['tested_agi_accepts']),
            ('rejected', agi['rows'][1]['control_agi_accepts'], 0)):
        for model, count in (('control',control_count),('candidate',tested_count)):
            marks = sum(len(re.findall(r'^\[FETCHDBG:AGIPRIME\] .+$', p.read_text(), re.M))
                        for p in (root/'agi-r1'/label).glob(f'*/{model}-lat*-cycle.stdout'))
            assert marks == count
    assert all(sha(p)==h for p,h in pins.items())
    built = load(core/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(core/'obj/tb_ventium')==built['binary_sha256']
    leaf = load(root/'leaf-r1/closed.json')
    assert leaf['passed'] and leaf['pins_unchanged'] and len(leaf['rows'])==7
    assert [r['native_exit'] for r in leaf['rows'][:3]]==[0,0,0]
    assert all(r['expected_negative'] and r['native_exit']!=0 for r in leaf['rows'][3:])
    leaves = []
    for name, expected in (('system/matrix',72), ('faults-r1',2), ('agi-r1/candidate',12)):
        closed = load(root/name/'closed.json')
        assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
        found = sorted(p.parent for p in (root/name).glob('*/golden.vtrace'))
        assert len(found)==expected
        leaves.extend(found)
    total, cycle_total, commands, paired = 0,0,0,0
    for leafpath in leaves:
        # The two drivers use intentionally distinct, recorded filename formats.
        matrix = leafpath.parent.name in ('matrix','candidate')
        for latency in (0,7):
            for mode in ('cycle-func','cycle'):
                stem = f'{{}}-lat{latency}-{mode}' if matrix else f'{{}}-{latency}-{mode}'
                streams=[]
                for model in ('control','candidate'):
                    label=stem.format(model)
                    assert load(leafpath/(label+'.exit.json'))['native_exit']==133
                    argv=load(leafpath/(label+'.command.json'))
                    assert '--l1-axi' in argv and '--'+mode in argv and '--system' in argv
                    streams.append(tracefmt.read_trace(str(leafpath/(label+'.vtrace'))).records)
                    if model=='candidate' and mode=='cycle':
                        text=(leafpath/(label+'.stdout')).read_text()
                        commands+=len(re.findall(r'\[FPEARLY\] ACCEPT ',text))
                assert streams[0]==streams[1],(leafpath,mode,latency)
                if mode=='cycle-func': total+=len(streams[1])
                else:
                    cycle_total+=len(streams[1])
                    paired+=sum(r.get('pipe')=='V' and r.get('paired',False) for r in streams[1])
    canonical=load(core/'verify-closed.json')
    assert canonical['pins_unchanged'] and not canonical['masks_or_goldens_or_bands_changed']
    assert len(canonical['deltas'])==20 and all(r['same_records'] for r in canonical['deltas'])
    # These are existing failures, never promoted to a pass by A/B equivalence.
    assert canonical['canonical_gate_native_exit']==2 and not canonical['canonical_gate_passed']
    owners={}
    for name in ('core','system','verify','faults','agi','leaf'):
        unit=f'ventium-fp-exec-{name}-oct10.service'
        props=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
            '-pSubState','-pMainPID','-pInvocationID','-pExecMainStatus'],text=True).splitlines())
        assert props['MainPID']=='0' and props['SubState']==('failed' if name=='verify' else 'exited')
        assert props['ExecMainStatus']==('1' if name=='verify' else '0')
        owners[name]=props
    for p in (core/'build-closed.json', core/'verify-closed.json', root/'leaf-r1/closed.json',
              root/'system/matrix/closed.json',root/'faults-r1/closed.json',
              root/'agi-r1/closed.json',root/'agi-r1/candidate/closed.json',
              root/'agi-r1/rejected/closed.json',Path(__file__)):
        pins[str(p)]=sha(p)
    result=dict(audit_complete=True,pins=pins,checked_input_pins=len(pins),owners=owners,
        model_sha256=built['binary_sha256'],directed_system_cases=len(leaves),
        identical_architectural_records=total,identical_cycle_records=cycle_total,
        integer_agi_regression=agi['rows'],rejected_shared_permit_caught=True,
        early_fp_accepts=commands,actual_v_retirements=paired,
        all_20_canonical_cycle_streams_identical=True,canonical_gate_passed=False,
        gameplay_ipc=None,standard_suite=False,hardware_acceptance=False)
    with (root/'audit.json').open('x') as f:
        json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)


if __name__=='__main__':
    main()
