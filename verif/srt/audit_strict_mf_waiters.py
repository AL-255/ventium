"""Independently re-read all closed waiter tests, executable opcodes and traces."""
import argparse
import json
from pathlib import Path
import re
import subprocess

import run_strict_mf_waiters as runner

OPCODES={
    'fwait':'9b','fnop':'d9d0','fld1':'d9e8','fchs':'d9e0','fabs':'d9e1',
    'fxch':'d9c9','ffree':'ddc7','fincstp':'d9f7','fdecstp':'d9f6',
    'fld32':'d905c0200000','fld64':'dd05c0200000','fld80':'db2dc0200000',
    'fild16':'df05c0200000','fild32':'db05c0200000','fild64':'df2dc0200000',
    'fst32':'d91500210000','fst64':'dd1500210000','fstp80':'db3d00210000',
    'fstreg':'ddd0','fist16':'df1500210000','fist32':'db1500210000',
    'fadd32':'d805c0200000','fsub32':'d825c0200000','fmul32':'d80dd0200000',
    'fdiv32':'d835d0200000','fcom':'d8d0','fucom':'dde1','ftst':'d9e4','fldcw':'d92d24200000',
}


def grade(log,trace,native_exit):
    records=trace.records
    assert records and trace.mode=='func' and trace.x87 and trace.hdr['sys']
    assert all(set(('fctrl','fstat','ftag',*('st'+str(i) for i in range(8))))<=set(r) for r in records)
    assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED',log)
    final={k:int(records[-1][k],0) for k in ('eax','ebx','ecx','esi','edi')}
    faults=re.findall(r'^\[FAULT\] vec=(\d+)\b',log,re.M)
    v=int(re.search(r'pairedV=(\d+)',log)[1])
    clocks=int(re.search(r'^  clocks\s+(\d+)',log,re.M)[1])
    backing=int(re.search(r'^\[L1DPERF\] fill cycles=\d+ backing-wait=\d+ backing-ack=(\d+)$',log,re.M)[1])
    # The default-quiesce banner is intentionally absent with --quiesce.
    # Audit the actual native --l1-axi argv below and positive L1 activity here.
    assert v>0 and backing>0
    passed=(native_exit==133 and final==dict(eax=0x42,ebx=3,ecx=2,esi=4,edi=0x42)
            and faults==['7','7','16','7','16'])
    return dict(passed=passed,final=final,faults=faults,v=v,clocks=clocks,
                backing_acks=backing,records=len(records))


def check_delivery_records(records,targets,handlers,instruction_size):
    # core_int_deliver.svh deliberately emits a post-delivery record at the
    # faulting PC. It is not successful execution of the waiting instruction.
    # Require those exact handler entries plus one successful retry; do not
    # drop delivery records or pretend all matching PCs are ordinary retires.
    for name,pc in targets.items():
        entries=[i for i,r in enumerate(records) if int(r['pc'],0)==pc]
        expected=['mf_entry'] if name=='case_mf_fld1' else ['nm_entry','mf_entry']
        assert len(entries)==len(expected)+1
        for i,handler in zip(entries,expected):
            r=records[i]
            assert int(r['esp'],0)==0x8ff4
            assert int(r['fstat'],0)&0x80ff==0x8090
            assert bool(int(r['cr0'],0)&8)==(handler=='nm_entry')
            assert int(records[i+1]['pc'],0)==handlers[handler]
        retry=entries[-1]
        assert int(records[retry]['esp'],0)==0x9000
        assert int(records[retry]['fstat'],0)&0x8080==0
        assert int(records[retry]['cr0'],0)&0xc==0
        assert int(records[retry+1]['pc'],0)==pc+instruction_size


def audit(root,unit):
    root=Path(root).resolve(strict=True)
    assert __debug__ and root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    load=lambda p:json.loads(p.read_text())
    start,done=[load(root/n) for n in ('started.json','closed.json')]
    state=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
        '-p','ActiveState','-p','SubState','-p','MainPID','-p','InvocationID','-p','Result',
        '-p','ExecMainStatus','-p','MemoryPeak'],text=True,timeout=5).splitlines())
    assert state['InvocationID']==start['invocation'] and state['MainPID']=='0'
    assert state['ActiveState']=='active' and state['SubState']=='exited'
    assert state['Result']=='success' and state['ExecMainStatus']=='0'
    assert done['completed'] and done['candidate_passed'] and done['pins_unchanged'] and not done['errors']
    assert not done['standard_suite'] and not done['hardware_acceptance'] and not done['qemu_differential']
    assert start['cycle_mode']==1 and not start['debugger_step'] and not start['snapshots']
    assert start['definitions']['parent']==start['definitions']['candidate']
    assert len(start['definitions']['candidate'])==153
    assert set(OPCODES)==set(runner.WAITERS)
    # JSON stores the fixture's operand tuples as arrays. Compare serialized
    # metadata, never normalize architectural records or exception status.
    assert start['vectors']==json.loads(json.dumps(runner.vectors()))
    pins=dict(start['pins'])
    assert all(runner.base.sha(p)==h for p,h in pins.items())
    rows=done['rows'];assert len(rows)==522
    expected={(v['name'],w,lat,m) for v in runner.vectors() for w in OPCODES
              for lat in (0,7,31) for m in runner.MODELS}
    actual={(r['vector'],r['waiter'],r['latency'],r['model']) for r in rows}
    assert actual==expected and len(actual)==len(rows)
    opcodes={};counts={m:dict(passed=0,failed=0,records=0,v=0) for m in runner.MODELS}
    for row in rows:
        folder=root/(row['vector']+'-'+row['waiter'])
        key=folder.name
        if key not in opcodes:
            image=(folder/'test.bin').read_bytes()
            assert len(image)==65536
            nm=subprocess.check_output(['nm','-n',str(folder/'test.elf')],text=True,timeout=5)
            symbols={parts[2]:int(parts[0],16) for line in nm.splitlines()
                     if len(parts:=line.split())==3 and parts[1].lower() in ('t','a')}
            targets={n:symbols[n] for n in ('case_mf_fld1','case_both_fld1')}
            instruction=bytes.fromhex(OPCODES[row['waiter']])
            for pc in targets.values():
                assert image[pc-0xf0000:pc-0xf0000+len(instruction)]==instruction
            opcodes[key]=(targets,{n:symbols[n] for n in ('nm_entry','mf_entry')})
        prefix=row['model']+'-lat'+str(row['latency'])
        log=folder/(prefix+'.log');trace=folder/(prefix+'.vtrace')
        native=load(folder/(prefix+'.closed.json'))
        assert native==row['native'] and native['actual_wait'] and native['observed']
        observed=native['observed'];assert not Path('/proc',str(observed['pid'])).exists()
        assert observed['cpu']==12 and observed['argv']==native['command']
        command=native['command'];model=Path(command[0])
        assert runner.base.sha(model)==runner.MODELS[row['model']][1]
        assert all(flag in command for flag in ('--system','--cosim','--cycle-func','--l1-axi','--x87'))
        assert not any('step' in s.lower() or 'breakpoint' in s.lower() for s in command)
        assert runner.base.sha(log)==native['log_sha256']
        assert runner.base.sha(trace)==row['trace_sha256']
        assert runner.base.sha(folder/'test.bin')==row['image_sha256']
        parsed=runner.base.tracefmt.read_trace(str(trace))
        observed_grade=grade(log.read_text(),parsed,native['native_exit'])
        assert all(row[k]==v for k,v in observed_grade.items())
        positive=row['model']!='control' or row['waiter'] in ('fwait','fnop')
        assert observed_grade['passed']==positive
        if positive:
            targets,handlers=opcodes[key]
            check_delivery_records(parsed.records,targets,handlers,len(bytes.fromhex(OPCODES[row['waiter']])))
        counter=counts[row['model']]
        counter['passed' if observed_grade['passed'] else 'failed']+=1
        counter['records']+=len(parsed.records);counter['v']+=observed_grade['v']
    for offset in range(0,len(rows),3):
        old,new=rows[offset+1:offset+3]
        assert old['model']=='parent' and new['model']=='candidate'
        for key in ('passed','final','faults','v','clocks','backing_acks','records','trace_sha256'):
            assert old[key]==new[key],key
    for p in (Path(__file__).resolve(),Path(runner.__file__).resolve()):pins[str(p)]=runner.base.sha(p)
    artifacts={str(p):runner.base.sha(p) for p in root.rglob('*') if p.is_file()}
    assert all(runner.base.sha(p)==h for p,h in pins.items())
    return dict(passed=True,owner=state,rows=522,forms=29,programs=58,models=runner.MODELS,
        counts=counts,paired_parent_traces=174,opcodes_checked=116,exact_parent_clocks=True,
        pins=pins,artifacts=artifacts,source_pins_checked=len(pins),seconds=done['seconds'],
        qemu_differential=False,canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run',type=Path,required=True);ap.add_argument('--unit',required=True)
    args=ap.parse_args();result=audit(args.run,args.unit)
    with (args.run/'audit.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','artifacts')},indent=2))
