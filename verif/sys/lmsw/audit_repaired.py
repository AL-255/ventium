"""Independently recheck LMSW source closure and closed test evidence.

Successful audit is not a green canonical/fault gate, standard suite or FPGA
acceptance. Retain the 16 oracle disagreements explicitly.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

import prepare_lmsw as recipe
from run_probe import REPO, sha
sys.path.insert(0, str(REPO/'verif/diff'))
import tracefmt

MODEL = 'fddb1fd3f7b677c44ddcc320808a9b756e45adc38718ff4d08b1dedb94d6b52b'
OWNERS = {
    'core': ('3cee5792ce6041f18a112ea19a5fbbf1', 0),
    'diff': ('6302aed3f66244ca88f1c5b52af1d570', 0),
    'fault': ('accf61b8af174122bce140d02e6f55d7', 1),
    'privilege': ('423e618642a94eabb93216d61f796593', 0),
    'verify': ('cf88a266b11a4708bdb35ae7e163f518', 1),
    'replay': ('1f465bf37afb4799b9dd116ee4eb96f8', 0),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root, out = args.root.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and out.is_relative_to(root) and not out.exists()
    pins, owners = {}, {}
    def pin(path):
        path = Path(path); digest = sha(path)
        assert str(path) not in pins or pins[str(path)] == digest
        pins[str(path)] = digest
        return path
    def load(path): return json.loads(pin(path).read_text())
    def check(mapping):
        for path,digest in mapping.items(): assert sha(pin(path)) == digest
    for name,(invocation,code) in OWNERS.items():
        unit = 'ventium-lmsw-'+name+'-oct13-r1.service'
        state = dict(line.split('=',1) for line in subprocess.check_output([
            'systemctl','--user','show',unit,'-p','MainPID','-p','InvocationID',
            '-p','ExecMainStatus','-p','SubState','-p','Result'],text=True).splitlines())
        assert state['MainPID']=='0' and state['InvocationID']==invocation
        assert state['ExecMainStatus']==str(code) and state['SubState']==('exited' if code==0 else 'failed')
        assert state['Result']==('success' if code==0 else 'exit-code')
        owners[unit]=state
    core = root/'lmsw-core-r1'; parent = root/'endpoint-map-core-r1'
    built, before = load(core/'build-closed.json'),load(core/'build-started.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(pin(core/'obj/tb_ventium'))==built['binary_sha256']==MODEL
    assert len(before['definitions'])==len(set(before['definitions']))==152
    assert before['invocation']==before['scope']['InvocationID']
    check(before['pins'])
    files = sorted(str(p.relative_to(core/'candidate')) for p in (core/'candidate').rglob('*') if p.is_file())
    assert len(files)==195
    assert files==sorted(str(p.relative_to(parent/'candidate')) for p in (parent/'candidate').rglob('*') if p.is_file())
    changes = [name for name in files if sha(pin(core/'candidate'/name))!=sha(pin(parent/'candidate'/name))]
    assert changes==before['changes']==sorted('rtl/core/'+name for name in recipe.PARENTS)
    for name in recipe.PARENTS:
        assert recipe.transform((parent/'candidate/rtl/core'/name).read_text(),name)==(core/'candidate/rtl/core'/name).read_text()
    total_records = 0
    for kind,count,passing in (('diff',16,16),('fault',44,28),('privilege',32,32)):
        folder = root/('lmsw-'+kind+'-r1')
        closed, started = load(folder/'closed.json'),load(folder/'started.json')
        assert closed['pins_unchanged'] and not closed['errors'] and len(closed['rows'])==count
        assert closed['passed']==(passing==count)
        check(started['pins'])
        if 'pins' in closed: check(closed['pins'])
        if 'artifacts' in closed: check(closed['artifacts'])
        assert sum(bool(row['passed']) for row in closed['rows'])==passing
        if kind=='privilege': check(load(folder.with_suffix('.driver.json'))['pins'])
        for row in closed['rows']:
            if kind=='diff':
                rtl = folder/(row['name']+'.rtl.vtrace'); golden = folder/(row['name']+'.qemu.vtrace')
                assert sha(pin(rtl))==row['rtl_sha256'] and sha(pin(golden))==row['golden_sha256']
            else:
                case_name='-'.join(k.lower()+str(v) for k,v in row['case'].items())
                check(row['artifacts'])
                rtl = folder/case_name/'rtl.vtrace'; golden = folder/case_name/'golden.vtrace'
                assert row['rtl_self_check']
            a,b = tracefmt.read_trace(str(pin(golden))),tracefmt.read_trace(str(pin(rtl)))
            assert a.sys and b.sys and a.mode==b.mode=='func' and row['records']==len(b.records)
            assert row['rtl_exit']==133 and (int(b.records[-1]['eax'],16)&255)==0x42
            if row['passed']:
                assert row['qemu_exit']==133 and row['golden_exit']==0 and row['compare_exit']==0
            else:
                assert kind=='fault' and row['case']['CASE'] in (3,5,6,7)
                assert row['qemu_exit']==135 and row['golden_exit']==0 and row['compare_exit']==1
            total_records += len(b.records)
    verified, vstart = load(core/'verify-closed.json'),load(core/'verify-started.json')
    assert verified['pins_unchanged'] and verified['canonical_gate_native_exit']==2 and not verified['canonical_gate_passed']
    assert not verified['masks_or_goldens_or_bands_changed']
    assert 'func totals: 7 PASS / 101 FAIL / 108 total' in pin(core/'generic.log').read_text()
    check(vstart['pins'])
    assert len(verified['deltas'])==20 and all(r['same_records'] for r in verified['deltas'])
    for row in verified['deltas']:
        a,b = [tracefmt.read_trace(str(pin(p/'generic-work'/row['name']))) for p in (parent,core)]
        assert a.records==b.records
    folder=root/'lmsw-replay-r1'; replay=load(folder/'closed.json')
    assert replay['same_input_regression_passed'] and replay['pins_unchanged'] and not replay['errors']
    assert len(replay['rows'])==108 and replay['records']==80800
    check(load(folder/'started.json')['pins']); check(load(folder.with_suffix('.driver.json'))['pins'])
    for row in replay['rows']:
        a,b,c=[tracefmt.read_trace(str(pin(p))) for p in (
            folder/row['case']/'control.vtrace',folder/row['case']/'candidate.vtrace',
            core/'generic-work'/(row['case']+'.func_rtl.vtrace'))]
        assert a.records==b.records==c.records and len(b.records)==row['records']
    pin(Path(__file__)); pin(Path(recipe.__file__)); check(pins)
    result=dict(audit_passed=True, model=MODEL, changed_files=changes, owners=owners, pins=pins,
        directed_rtl_self_check_cases=92, directed_qemu_differential_passes=76, directed_records=total_records,
        oracle_disagreement_cases=16, fault_differential_gate_passed=False, canonical_gate_passed=False,
        canonical_cycle_traces_identical=20, canonical_replay_cases=108, canonical_replay_records=80800,
        standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None)
    with out.open('x') as stream: json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','owners')},indent=2))


if __name__=='__main__': main()
