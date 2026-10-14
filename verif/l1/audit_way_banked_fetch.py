"""Regrade closed fetch-boundary artifacts, not merely their PASS markers.

No model launches or trace edits. The supervisor's raw result defaults to FAIL;
only the actual wait, clean closure, original witnesses and full differential
can establish acceptance. Per-child CPU affinity was not observed in this run.
"""
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/fetchguard'))
import run_probe_boundary_ab as original

sha=original.sha
checks=original.checks
contracts=original.contracts
tracefmt=original.tracefmt


def load(path):
    return json.loads(path.read_text())


def closed_streams(leaf,label,expected):
    row=load(leaf/(label+'.exit.json'))
    assert row['launched'] and row['actual_wait'] and row['group_closed']
    assert row['actual_return_code']==expected and not row['timed_out']
    assert not any(row[key] for key in ('descendant_leak','cleanup_errors','cleanup_signals','signals_after_reap'))
    streams=[]
    for suffix in ('stdout','stderr'):
        path=leaf/(label+'.'+suffix)
        assert sha(path)==row[suffix+'_sha256']
        streams.append(path.read_text())
    return row,streams


def main():
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    data=scratch/'ventium-data-size.v2HaTO2X'
    root=data/'way-banked-fetch-r1'
    started,closed=load(root/'started.json'),load(root/'closed.json')
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert started['cycle_mode']==1 and len(started['profiles']['candidate'])==152
    pins=dict(started['pins'])
    assert all(sha(p)==h for p,h in pins.items())
    owner=dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show','ventium-way-banked-fetch-oct14-r1.service',
        '-pMainPID','-pSubState','-pInvocationID','-pExecMainStatus'],text=True).splitlines())
    assert owner==dict(MainPID='0',SubState='exited',ExecMainStatus='0',InvocationID=started['invocation'])
    models={name:data/(directory+'-core-r1')/'obj/tb_ventium' for name,directory in
            (('parent','fp-compare'),('candidate','way-banked'))}
    expected_hashes={'parent':'5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8',
                     'candidate':'139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'}
    for name,model in models.items():
        assert sha(model)==expected_hashes[name]
        record=model.parent/'Vventium_top__verFiles.dat'
        assert contracts.validate_build(model,sha(model),record,sha(record),[])==started['profiles'][name]
    checks.validate_manifest(load(original.HERE/'manifest.json'))
    rows=[]; qemu_comparisons=0; native_executions=0
    for case in checks.CASES:
        leaf=root/f'case{case}'
        image=data/'fetch-fixtures'/f'pfetchbound_{case}.bin'
        sym,bios=contracts.symbols(image.with_suffix('.elf')),image.read_bytes()
        checks.validate_image(case,sym,bios)
        free,_=closed_streams(leaf,'free-qemu',133)
        generated,logs=closed_streams(leaf,'golden',0)
        assert str(contracts.QEMU) in free['argv'] and str(image) in free['argv']
        assert str(contracts.QEMU) in generated['argv'] and str(image) in generated['argv']
        gold=contracts.read_complete_trace(leaf/'golden.vtrace')
        checks.grade_golden(case,gold,''.join(logs),sym,bios,0,133)
        for latency in (0,7):
            both={}
            for name,model in models.items():
                traces={}; clocks={}; witnesses=0
                for mode in ('cycle-func','cycle'):
                    label=f'{name}-lat{latency}-{mode}'
                    receipt,(out,err)=closed_streams(leaf,label,133)
                    argv=receipt['argv']; native_executions+=1
                    assert argv==['env',f'AXI_RLAT={latency}',f'AXI_WLAT={latency}',str(model),
                        '--cosim','--system','--'+mode,'--l1-axi','--image',str(image),
                        '--out',str(leaf/(label+'.vtrace')),'--max-insn',str(checks.MAX_INSN),
                        '--max-cycles','1000000','--quiesce','4096',
                        '+ven_faultlog','+ven_fetch_probe_payload_witness']
                    trace=tracefmt.read_trace(str(leaf/(label+'.vtrace')))
                    traces[mode]=trace.records
                    assert [r['n'] for r in trace.records]==list(range(len(gold.records)))
                    assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records]
                    assert not original.native.FATAL.search(out+err)
                    if mode=='cycle-func':
                        grade=checks.grade_native(case,trace,out,err,sym,bios,133)
                        clocks[mode]=grade['clocks']
                        assert original.compare.compare_func(gold,trace,False,0xffffffff,False,20,
                            io.StringIO(),sys_both=True)==0
                        qemu_comparisons+=1
                    else:
                        clocks[mode]=int(re.search(r'after \d+ retired in (\d+) clocks',err)[1])
                    backing=re.findall(r'^\[L1DPERF\] fill cycles=(\d+) backing-wait=(\d+) backing-ack=(\d+)$',out,re.M)
                    assert len(backing)==1 and int(backing[0][0])>0 and int(backing[0][2])>0
                    witnesses+=len(re.findall(r'^\[FETCH-PROBE-PAYLOAD\]',out,re.M))
                assert clocks['cycle']==clocks['cycle-func']
                both[name]=traces
                rows.append(dict(case=case,model=name,latency=latency,records=len(traces['cycle']),
                    clocks=clocks['cycle'],probe_witnesses=witnesses,
                    paired_v=sum(r.get('pipe')=='V' and r.get('paired') for r in traces['cycle'])))
            assert both['parent']==both['candidate']
    key=lambda row:(row['case'],row['model'],row['latency'])
    assert sorted(rows,key=key)==sorted(closed['rows'],key=key)
    candidate=[r for r in rows if r['model']=='candidate']
    assert sum(r['records'] for r in candidate)==closed['candidate_records']==21832
    assert sum(r['paired_v'] for r in candidate)==closed['paired_v']==4968
    assert sum(r['probe_witnesses'] for r in candidate)==closed['probe_witnesses']==44
    assert qemu_comparisons==88 and native_executions==176
    assert all(sha(p)==h for p,h in pins.items())
    artifacts={str(p):sha(p) for p in root.rglob('*') if p.is_file()}
    artifacts[str(Path(__file__).resolve())]=sha(__file__)
    result=dict(passed=True,owner=owner,pins_checked=len(pins),artifacts=artifacts,cases=22,
        qemu_comparisons=qemu_comparisons,native_rtl_executions=native_executions,
        candidate_records=21832,candidate_v_retirements=4968,probe_witnesses=44,
        actual_child_affinity_observed=False,canonical_gate_passed=False,
        standard_suite=False,physical_board=False,gameplay_ipc=None)
    with (root/'audit.json').open('x') as stream: json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'},indent=2))


if __name__=='__main__':
    main()
