"""Audit closed corner tests without turning oracle disagreements into passes.

The fault driver's overall differential result MUST remain false: Intel-spec
LOCK/segment witnesses are reported separately, never as QEMU equivalence.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

from run_probe import HERE, REPO, sha
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for key in ('privilege','fault','out'):
        ap.add_argument('--'+key,required=True,type=Path)
    args = ap.parse_args()
    pins,owners,runs = {},{},{}
    for label,root,unit,status in (
        ('privilege',args.privilege,'ventium-smsw-privilege-oct13-r2.service',0),
        ('fault',args.fault,'ventium-smsw-fault-oct13-r1.service',1)):
        before,done = [json.loads((root/file).read_text()) for file in ('started.json','closed.json')]
        assert done['pins_unchanged'] and not done['errors']
        assert all(sha(p)==h for p,h in before['pins'].items())
        props = dict(line.split('=',1) for line in subprocess.check_output([
            'systemctl','--user','show',unit,'-p','MainPID','-p','ExecMainStatus','-p','InvocationID'],text=True).splitlines())
        assert props == dict(MainPID='0',ExecMainStatus=str(status),InvocationID=before['invocation'])
        owners[label] = props
        pins.update(before['pins'])
        pins[str(root/'started.json')] = sha(root/'started.json')
        pins[str(root/'closed.json')] = sha(root/'closed.json')
        assert sorted(done['rows'],key=lambda r:str(sorted(r['case'].items())))
        assert {tuple(sorted(r['case'].items())) for r in done['rows']} == {tuple(sorted(c.items())) for c in before['cases']}
        runs[label] = done
    assert runs['privilege']['passed'] and len(runs['privilege']['rows'])==60
    assert not runs['fault']['passed'] and len(runs['fault']['rows'])==45
    differential_cases = differential_records = spec_cases = spec_records = 0
    for label,root in (('privilege',args.privilege),('fault',args.fault)):
        for row in runs[label]['rows']:
            assert all(sha(p)==h for p,h in row['artifacts'].items())
            pins.update(row['artifacts'])
            folder,c = root/row['name'],row['case']
            system_trace = tracefmt.read_trace(str(folder/'candidate.vtrace'))
            assert system_trace.sys and system_trace.mode=='func' and not system_trace.x87
            assert int(system_trace.records[-1]['eax'],16)&255==0x42
            native = json.loads((folder/'candidate-native.json').read_text())
            assert native['exit']==133 and native['observed_affinity']
            diff = subprocess.run(['taskset','-c','0,1',sys.executable,'-B',
                REPO/'verif/diff/compare.py','--mode','func',folder/'golden.vtrace',folder/'candidate.vtrace'],
                capture_output=True,text=True,timeout=10)
            if label=='privilege' or c['CASE']>=4:
                assert row['passed'] and diff.returncode==0 and 'sys compared: True' in diff.stdout
                differential_cases += 1
                differential_records += len(system_trace.records)
            else:
                # Keep the native QEMU and full-trace disagreement visible.
                assert not row['passed'] and row['qemu_native_exit']==135 and diff.returncode==1
                assert 'field=esp:' in diff.stdout
                assert row['rtl_native_exit']==133 and row['compare_exit']==1
                spec_cases += 1
                spec_records += len(system_trace.records)
            if label=='fault':
                symbols = {line.split()[2]:int(line.split()[0],16) for line in
                    subprocess.check_output(['nm','-n',folder/'probe.elf'],text=True).splitlines() if len(line.split())==3}
                pc,after = [symbols[key] for key in ('smsw_probe','smsw_after')]
                encoded = (folder/'probe.bin').read_bytes()[pc-0xf0000:after-0xf0000]
                prefix = ([0xf0] if c['CASE']==0 else []) + ([0x66] if c['CONTROL'] or not c['OP32'] else [])
                prefix += [] if c['ADDR32'] else [0x67]
                opcode = [0x89,0x05 if c['ADDR32'] else 0x06] if c['CONTROL'] else [0x0f,0x01,0x25 if c['ADDR32'] else 0x26]
                assert encoded==bytes(prefix+opcode)+int(0xfff).to_bytes(4 if c['ADDR32'] else 2,'little')
                if c['CASE']==8:
                    assert not row['faults']
                else:
                    assert len(row['faults'])==1
                    match = re.fullmatch(r'\[FAULT\] vec=(\d+) err=([0-9a-f]+) pc=([0-9a-f]+) state=\d+ v86=0 depth=0',row['faults'][0])
                    expected = 6 if c['CASE']==0 else 13 if c['CASE']<4 else 14
                    error = 2 if c['CASE'] in (4,6) else 3 if c['CASE'] in (5,7) else 0
                    assert match and (int(match[1]),int(match[2],16),int(match[3],16))==(expected,error,pc)
    assert differential_cases==85 and spec_cases==20
    manual = REPO/'ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf'
    for path in (Path(__file__),manual,REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/target/i386/tcg/translate.c',
                 REPO/'verif/sys/run-seg-gate.sh',REPO/'verif/sys/run-pnullseg-gate.sh'):
        pins[str(path)] = sha(path)
    assert all(sha(p)==h for p,h in pins.items())
    result = dict(audit_passed=True,owners=owners,differential_cases=differential_cases,
        differential_records=differential_records,intel_spec_only_cases=spec_cases,intel_spec_only_records=spec_records,
        complete_fault_differential_gate_passed=False,canonical_gate_passed=False,
        hardware_acceptance=False,standard_suite=False,gameplay_ipc=None,pins=pins,
        specification='Intel 241430-004, printed pages 25-215 and 25-297; PDF pages 832 and 914 visually checked')
    with args.out.open('x') as stream:
        json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)


if __name__=='__main__':
    main()
