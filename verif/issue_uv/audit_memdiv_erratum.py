#!/usr/bin/env python3
"""Recheck complete memory-FDIV traces, exact opcodes and real AXI/V activity."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

from run_memdiv_erratum import MODELS, REPO, rounded80, sha, tracefmt


def require_value(records,pc,expected):
    rows=[r for r in records if int(r['pc'],0)==pc]
    assert len(rows)==1 and int(rows[0]['st0'],0)==expected


def audit(root,unit):
    start=json.loads((root/'started.json').read_text())
    closed=json.loads((root/'closed.json').read_text())
    assert closed['passed'] and not closed['errors'] and closed['pins_unchanged']
    assert all(sha(p)==h for p,h in start['pins'].items())
    assert start['affinity']==[4,5,6,7] and len(closed['measurements'])==128
    assert not closed['standard_suite'] and not closed['canonical_gate'] and closed['gameplay_ipc'] is None
    owner=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
        '-p','SubState','-p','MainPID','-p','ExecMainStatus','-p','InvocationID','-p','ControlGroup'],text=True).splitlines())
    assert owner==dict(SubState='exited',MainPID='0',ExecMainStatus='0',
                       InvocationID=start['invocation'],ControlGroup='')
    pins={str(p):sha(p) for p in (Path(__file__),root/'started.json',root/'closed.json')}
    candidate_records=paired=negative_checks=0; rows=[]
    for fmt in range(4):
        for reverse in (0,1):
            folder=root/f'f{fmt}-r{reverse}'
            symbols={r[2]:int(r[0],16) for s in subprocess.check_output(['/usr/bin/nm',str(folder/'fixture.elf')],
                     text=True).splitlines() if len(r:=s.split())==3}
            flat=(folder/'fixture.flat').read_bytes(); offset=symbols['quotient']-0x08048000
            assert flat[offset:offset+2]==bytes(([0xd8,0xdc,0xda,0xde][fmt],0x3d if reverse else 0x35))
            traces={}
            for bug in (0,1):
                expected=(0x3fffaab7f6392a768638 if bug else rounded80(4195835,3145727)) if fmt<3 else rounded80(29,7)
                for latency in (0,7):
                    for model,digest in MODELS.items():
                        assert sha(start['models'][model])==digest
                        for mode in ('cycle-func','cycle'):
                            label=f'{model}-bug{bug}-lat{latency}-{mode}'
                            log=(folder/(label+'.log')).read_text()
                            command=json.loads((folder/(label+'.command.json')).read_text())
                            assert command==[start['models'][model],'--image',str(folder/'fixture.flat'),
                                '--load','0x08048000','--entry','0x08048000','--out',str(folder/(label+'.vtrace')),
                                '--x87','--'+mode,'--l1-axi','--errata',str(bug),'--max-insn','200','--quiesce','20000']
                            result=json.loads((folder/(label+'.exit.json')).read_text())
                            assert result['native_exit']==0 and result['reaped'] and result['affinity']==[4,5,6,7]
                            assert not Path('/proc',str(result['pid'])).exists()
                            acks=re.findall(r'\[L1DPERF\] fill cycles=\d+ backing-wait=\d+ backing-ack=(\d+)',log)
                            assert len(acks)==1 and int(acks[0])>0,label
                            trace=tracefmt.read_trace(str(folder/(label+'.vtrace')))
                            assert trace.mode==('func' if mode=='cycle-func' else 'cycle')
                            records=trace.records; traces[bug,latency,model,mode]=records
                            assert int(records[-1]['pc'],0)==symbols['exit_int']
                            if mode=='cycle-func':
                                require_value(records,symbols['quotient'],expected)
                                if model=='candidate': candidate_records+=len(records)
                                # The observed clean result must not satisfy the
                                # buggy-result check, or vice versa. No trace edits.
                                if fmt<3:
                                    wrong=rounded80(4195835,3145727) if bug else 0x3fffaab7f6392a768638
                                    try: require_value(records,symbols['quotient'],wrong)
                                    except AssertionError: negative_checks+=1
                                    else: raise AssertionError('ignored erratum-value check')
                            else:
                                v=[i for i,r in enumerate(records) if r['pipe']=='V' and r['paired']]
                                assert v and all(i>0 and records[i-1]['pipe']=='U' and
                                                 records[i-1]['cyc']==records[i]['cyc'] for i in v)
                                if model=='candidate': paired+=len(v)
                    assert traces[bug,latency,'control','cycle-func']==traces[bug,latency,'candidate','cycle-func']
                    old,new=[traces[bug,latency,k,'cycle'] for k in MODELS]
                    assert [(r['n'],r['pc']) for r in old]==[(r['n'],r['pc']) for r in new]
                    assert all(0<=b['cyc']-a['cyc']<=1 for a,b in zip(old,new))
                    rows.append(dict(format=fmt,reverse=reverse,bug=bug,latency=latency,
                                     added_clocks=new[-1]['cyc']-old[-1]['cyc'],expected_st0=hex(expected)))
            for p in folder.iterdir():
                assert p.is_file() and not p.is_symlink(); pins[str(p)]=sha(p)
    assert negative_checks==48 and len(rows)==32
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(passed=True,owner=owner,artifact_pins=pins,rows=rows,measurements=128,
        candidate_architectural_records=candidate_records,candidate_paired_v=paired,
        opposite_erratum_result_rejections=negative_checks,all_runs_actual_axi=True,
        canonical_gate=False,standard_suite=False,physical_board=False,gameplay_ipc=None)
    with (root/'audit.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('artifact_pins','rows')}))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',required=True,type=Path); parser.add_argument('--unit',required=True)
    args=parser.parse_args(); root=args.root.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch and root.is_relative_to(scratch) and root!=scratch
    audit(root,args.unit)
