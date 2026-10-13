"""Independently replay complete comparisons and check actual fault/retry flow."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

from run_probe import HERE,REPO,sha
import prepare_retry as fixture
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();pins={};owners={};cases=records=retries=controls=0
    for latency in (0,7,31):
        root=args.root/f'smsw-retry-l{latency}-r1'
        before,done=[json.loads((root/name).read_text()) for name in ('started.json','closed.json')]
        assert done['passed'] and done['pins_unchanged'] and not done['errors'] and len(done['rows'])==25
        assert before['axi_latency']==latency and len(before['definitions'])==152
        assert before['model_sha256']=='cbf749f16babd88fb5dcf508c2381d48b77dedd348e9b23a5ed9083de9f4e65e'
        assert all(sha(p)==h for p,h in before['pins'].items())
        assert (root/'retry.S').read_text()==fixture.transform((HERE/'fault.S').read_text())
        props=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',
            f'ventium-smsw-retry-l{latency}-oct13-r1.service','-pMainPID','-pSubState',
            '-pExecMainStatus','-pInvocationID'],text=True).splitlines())
        assert props==dict(MainPID='0',SubState='exited',ExecMainStatus='0',InvocationID=before['invocation'])
        owners[str(latency)]=props;pins.update(before['pins'])
        for name in ('started.json','closed.json'):pins[str(root/name)]=sha(root/name)
        assert {tuple(sorted(r['case'].items())) for r in done['rows']}=={
            tuple(sorted(c.items())) for c in before['cases']}
        for row in done['rows']:
            assert row['passed'] and row['qemu_native_exit']==row['rtl_native_exit']==133
            assert row['golden_exit']==row['compare_exit']==0
            assert all(sha(p)==h for p,h in row['artifacts'].items());pins.update(row['artifacts'])
            f=root/row['name'];c=row['case'];index=before['cases'].index(c)
            expected_pair=before['affinity'][(index%4)*2:(index%4)*2+2]
            for label in ('qemu-native','golden','candidate'):
                child=json.loads((f/(label+'-native.json')).read_text())
                assert child['observed_affinity'] and all(v==expected_pair for v in child['observed_affinity'].values())
                assert all(not (Path('/proc')/p).exists() for p in child['observed_affinity'])
            command=json.loads((f/'candidate-command.json').read_text())['argv']
            assert '--cycle-func' in command and '--l1-axi' in command and '--system' in command
            compare=subprocess.run([sys.executable,'-B',REPO/'verif/diff/compare.py','--mode','func',
                f/'golden.vtrace',f/'candidate.vtrace'],capture_output=True,text=True,timeout=10)
            assert compare.returncode==0 and 'sys compared: True' in compare.stdout
            symbols={s.split()[2]:int(s.split()[0],16) for s in subprocess.check_output([
                'nm','-n',f/'probe.elf'],text=True).splitlines() if len(s.split())==3}
            pc,after=[symbols[n] for n in ('smsw_probe','smsw_after')]
            encoded=(f/'probe.bin').read_bytes()[pc-0xf0000:after-0xf0000]
            prefix=([0x66] if c['CONTROL'] or not c['OP32'] else [])+([] if c['ADDR32'] else [0x67])
            opcode=[0x89,0x05 if c['ADDR32'] else 0x06] if c['CONTROL'] else [0x0f,0x01,0x25 if c['ADDR32'] else 0x26]
            assert encoded==bytes(prefix+opcode)+(0xfff).to_bytes(4 if c['ADDR32'] else 2,'little')
            tr=tracefmt.read_trace(str(f/'candidate.vtrace'))
            assert tr.sys and tr.mode=='func' and not tr.x87 and len(tr.records)==row['records']
            assert int(tr.records[-1]['eax'],16)&255==0x42
            visits=[r for r in tr.records if int(r['pc'],16)==pc]
            fault=c['CASE']!=8
            assert len(visits)==(2 if fault else 1)
            assert sum(int(r['pc'],16)==symbols['pf_handler'] for r in tr.records)==int(fault)
            assert sum(int(r['pc'],16)==after for r in tr.records)==1
            if fault:
                assert len(row['faults'])==1 and int(visits[0]['esp'],16)==0x8ff0
                match=re.fullmatch(r'\[FAULT\] vec=(\d+) err=([0-9a-f]+) pc=([0-9a-f]+) state=\d+ v86=0 depth=0',row['faults'][0])
                assert match and (int(match[1]),int(match[2],16),int(match[3],16))==(
                    14,2 if c['CASE'] in (4,6) else 3,pc)
                assert int(visits[-1]['cr2'],16)==(0x400fff if c['CASE'] in (4,5) else 0x401000)
                retries+=1
            else:
                assert not row['faults'];controls+=1
            final=visits[-1]
            assert int(final['esp'],16)==0x9000 and int(final['eflags'],16)&0xfd7==0x8d7
            expected=dict(eax=0x1234001b,ebx=0x11223344,ecx=0x22334455,edx=0x33445566,
                          ebp=0x44556677,esi=0x55667788,edi=0x66778899)
            assert all(int(final[k],16)==v for k,v in expected.items())
            cases+=1;records+=len(tr.records)
    assert (cases,retries,controls)==(75,60,15)
    pins[str(Path(__file__))]=sha(__file__)
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(passed=True,differential_cases=cases,records=records,retries=retries,controls=controls,
                owners=owners,pins=pins,canonical_gate_passed=False,standard_suite=False,
                hardware_acceptance=False,gameplay_ipc=None)
    with args.out.open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)


if __name__=='__main__':main()
