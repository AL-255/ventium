"""Recheck cold fixture traces and actual native children after owner closure."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

import run_v_load_payload_system as flow

base = flow.original


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    root = args.out.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    matrix = root/'matrix'
    load = lambda p: json.loads(p.read_text())
    start, done, adapter = load(matrix/'started.json'), load(matrix/'closed.json'), load(root/'adapter.json')
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert adapter['pins_unchanged'] and adapter['native_runner_exit'] == 0 and adapter['no_oom']
    assert adapter['result_sha256'] == base.sha(matrix/'closed.json')
    assert all(adapter['memory_events'][k] == '0' for k in ('oom','oom_kill','oom_group_kill'))
    pins = {**start['pins'], **adapter['pins']}
    assert all(base.sha(p) == h for p,h in pins.items())
    rows, records, native_children, case_count = [], 0, 0, 0
    owners = set()
    for label, _, _ in flow.PATTERNS:
        for reloc in (0,1):
            for offset in (0,31):
                leaf = matrix/f'{label}-r{reloc}-o{offset}'
                closed = load(leaf/'closed.json')
                assert closed['passed'] and len(closed['measurements']) == 4
                assert closed['image_sha256'] == base.sha(leaf/'fixture.bin')
                symbols = {s[2]:int(s[0],16) for line in subprocess.check_output([
                    'nm','-n',leaf/'fixture.elf'], text=True).splitlines()
                    if len(s:=line.split())==3 and s[0]!='U'}
                gold = base.tracefmt.read_trace(str(leaf/'golden.vtrace'))
                assert gold.sys and 100 < len(gold.records) < 2000
                assert int(gold.records[-1]['eax'],0)&255 == 0x42
                for latency in (0,7):
                    both = {}
                    for name, model in start['models'].items():
                        traces, clocks, immediate = {}, {}, {}
                        for mode in ('cycle-func','cycle'):
                            stem = f'{name}-lat{latency}-{mode}'
                            command = load(leaf/(stem+'.command.json'))
                            receipt = load(leaf/(stem+'.native.json'))
                            assert command[:3] == ['timeout','--kill-after=3s','45s']
                            assert command[3] == model and '--l1-axi' in command and '--'+mode in command
                            assert '+ven_pair_now_read_ack_witness' in command
                            assert receipt['native_exit'] == 133 and receipt['error'] is None and receipt['launcher_reaped']
                            matches = [r for r in receipt['actual'] if r['argv'] == command[3:]]
                            assert len(matches) == 1
                            actual = matches[0]
                            assert actual['affinity'] == [12] and actual['exe'] == str(Path(model).resolve())
                            owners.add(actual['cgroup'].strip().rsplit('/',1)[1])
                            proc = Path('/proc')/str(actual['pid'])
                            if proc.exists():
                                assert (proc/'stat').read_text().rsplit(')',1)[1].split()[19] != actual['starttime']
                            native_children += 1
                            trace = base.tracefmt.read_trace(str(leaf/(stem+'.vtrace')))
                            assert [r['n'] for r in trace.records] == list(range(len(gold.records)))
                            assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]
                            stdout, stderr = [(leaf/(stem+'.'+ext)).read_text() for ext in ('stdout','stderr')]
                            assert not base.native.FATAL.search(stdout+stderr)
                            base.check_faultlog.check_counts(base.check_faultlog.read_counts(stdout.splitlines()), {})
                            stop = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) after (\d+) retired in (\d+) clocks$',stderr,re.M)
                            assert len(stop) == 1 and int(stop[0][0]) == len(trace.records)
                            clocks[mode] = int(stop[0][1])
                            if mode == 'cycle-func':
                                with open(os.devnull,'w') as sink:
                                    assert base.compare.compare_func(gold,trace,False,0xffffffff,False,20,sink,sys_both=True) == 0
                                records += len(trace.records)
                            immediate[mode] = sum(int(pc,16) == symbols['hot_u'] for pc in
                                re.findall(r'^\[PAIR-NOW-READ-ACK\] pc=([0-9a-f]+) ',stdout,re.M))
                            traces[mode] = trace.records
                        assert clocks['cycle'] == clocks['cycle-func'] and immediate['cycle'] == immediate['cycle-func']
                        vr = [r for r in traces['cycle'] if int(r['pc'],0) == symbols['hot_load']]
                        assert len(vr) == 16
                        paired = sum(r.get('pipe') == 'V' and r.get('paired') for r in vr)
                        matches = [r for r in closed['measurements'] if r['model'] == name and r['latency'] == latency]
                        assert len(matches) == 1
                        row = matches[0]
                        assert (row['clocks'],row['records'],row['memory_v'],row['immediate']) == (
                            clocks['cycle'],len(gold.records),paired,immediate['cycle'])
                        rows.append(row)
                        both[name] = traces
                    assert both['control'] == both['candidate']
                case_count += 1
    assert len(rows) == len(done['measurements']) == 128 and native_children == 256 and case_count == 32
    assert sorted(rows,key=lambda r:json.dumps(r,sort_keys=True)) == sorted(done['measurements'],key=lambda r:json.dumps(r,sort_keys=True))
    assert len(owners) == 1
    unit = owners.pop()
    owner = dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
        '-pSubState','-pMainPID','-pExecMainStatus','-pInvocationID','-pMemoryPeak'],text=True).splitlines())
    assert owner['SubState'] == 'exited' and owner['MainPID'] == owner['ExecMainStatus'] == '0'
    assert owner['InvocationID'] == start['invocation'] and int(owner['MemoryPeak']) <= 1024**3
    assert done['fixture_only'] == (start['models']['control'] == start['models']['candidate'])
    artifacts = {str(p):base.sha(p) for p in root.rglob('*') if p.is_file()}
    artifacts[str(Path(__file__).resolve())] = base.sha(__file__)
    assert all(base.sha(p) == h for p,h in pins.items())
    result = dict(passed=True,unit=unit,owner=owner,pins_checked=len(pins),cases=case_count,
        native_simulator_children=native_children,complete_functional_records=records,
        fixture_only=done['fixture_only'],candidate_rtl_verified=not done['fixture_only'],
        coverage=done['coverage'],seconds=done['seconds'],artifacts=artifacts,
        standard_suite=False,physical_board=False,gameplay_ipc=None,timing_mhz=None)
    base.save(root/'audit.json',result)
    print(json.dumps({k:v for k,v in result.items() if k != 'artifacts'}))


if __name__ == '__main__':
    main()
