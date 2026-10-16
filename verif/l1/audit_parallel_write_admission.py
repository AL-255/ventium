"""Independently check closed native evidence for the parallel-write proposal."""
import argparse
import json
from pathlib import Path
import re
import subprocess

import prepare_parallel_write_admission as recipe
import run_parallel_write_admission as gate
from run_parallel_tag_cache import sha


def audit(root):
    pins, owners, runs = {}, {}, {}
    parent = root/'raw-prime-storage-fpga-r1/ventium/rtl/mem'
    original = {name:(parent/name).read_text() for name in recipe.PINS}
    changed = recipe.transform(original)
    for stage, count in (('leaf',9),('cache',1),('wrapper',2),('corners',2),('faults',18)):
        folder = root/('parallel-write-'+stage+'-r1')
        started = json.loads((folder/'started.json').read_text())
        closed = json.loads((folder/'closed.json').read_text())
        assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
        assert closed['stage'] == stage and len(closed['rows']) == count
        assert closed['gameplay_ipc'] is None and closed['fmax_mhz'] is None
        assert not any(closed[key] for key in ('whole_core','standard_suite','hardware_acceptance'))
        assert len(started['hardware_defines']) == 159 and len(started['defines']) == 158
        assert 'SYNTHESIS' not in started['defines'] and 'VEN_P54_DUAL_STORE_PAIR' in started['defines']
        unit = 'ventium-parallel-write-'+stage+'-oct16-r1.service'
        raw = subprocess.check_output(['systemctl','--user','show',unit,'-p','ActiveState',
            '-p','SubState','-p','MainPID','-p','Result','-p','InvocationID','-p','ExecMainStatus',
            '-p','ExecMainStartTimestampMonotonic','-p','ExecMainExitTimestampMonotonic'],text=True)
        owner = dict(line.split('=',1) for line in raw.splitlines() if '=' in line)
        if stage == 'leaf':
            assert owner['InvocationID'] == started['invocation']
        else:
            # build_scope creates a separate user scope; its inherited
            # INVOCATION_ID is not the outer oneshot service's invocation.
            native_raw = subprocess.check_output(['journalctl','--user',
                'USER_INVOCATION_ID='+started['invocation'],'-o','json','--no-pager'],text=True)
            events = [json.loads(line) for line in native_raw.splitlines()]
            assert events and all(event['USER_INVOCATION_ID']==started['invocation'] for event in events)
            assert all(event.get('USER_UNIT')=='ventium-ipc-parallel32.scope' for event in events)
            starts = [event for event in events if event.get('MESSAGE','').startswith('Started ')]
            assert len(starts)==1 and '--stage '+stage in starts[0]['MESSAGE']
            assert '--out /home/yukidama/external/tmp/'+root.name+'/'+folder.name in starts[0]['MESSAGE']
            assert int(owner['ExecMainStartTimestampMonotonic']) <= int(starts[0]['__MONOTONIC_TIMESTAMP'])
            assert int(starts[0]['__MONOTONIC_TIMESTAMP']) <= int(owner['ExecMainExitTimestampMonotonic'])
            ends = [event for event in events if event.get('MESSAGE','').startswith(
                'ventium-ipc-parallel32.scope: Consumed ')]
            assert len(ends)==1
            assert int(ends[0]['__MONOTONIC_TIMESTAMP']) <= int(owner['ExecMainExitTimestampMonotonic'])
            child_raw = subprocess.check_output(['journalctl','--user',
                '_SYSTEMD_INVOCATION_ID='+started['invocation'],'-o','json','--no-pager'],text=True)
            child_events = [json.loads(line) for line in child_raw.splitlines()]
            results = [json.loads(event['MESSAGE']) for event in child_events
                       if event.get('MESSAGE','').startswith('{"stage":')]
            assert len(results)==1 and results[0]['stage']==stage and results[0]['passed']
            assert results[0]['pins_unchanged'] and not results[0]['errors']
            owner['native_scope_invocation'] = started['invocation']
        assert owner['MainPID'] == '0' and owner['ExecMainStatus'] == '0' and owner['Result'] == 'success'
        assert (owner['ActiveState'],owner['SubState']) == ('active','exited')
        owners[stage] = dict(unit=unit,**owner)
        pins.update(closed['pins'])
        for name,text in changed.items(): assert (folder/name).read_text() == text
        rows = closed['rows']
        for row in rows:
            assert row['build_exit'] == 0 and row['native_affinity'] == [8]
            assert row['expected_failure'] == row['label'].startswith('mutant-')
            assert row['native_exit'] == (1 if row['expected_failure'] else 0)
            log = (folder/row['label']/'run.log').read_text()
            assert log == row['log']
            if row['expected_failure']:
                assert 'PARALLEL-WRITE-EQUATION-MISMATCH' in log
            else:
                assert not re.search(r'%Fatal|%Error|FATAL:|\bFAIL\b|MISMATCH',log)
            pins.update(row['artifacts'])
            if stage != 'leaf':
                assert '--assert' in row['command'] and '-j' in row['command']
                assert row['command'][row['command'].index('-j')+1] == '32'
                assert all('-Werror-'+name in row['command'] for name in
                           ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT'))
                assert '+define+SYNTHESIS' not in row['command']
                build = (folder/row['label']/'build.log').read_text()
                assert not re.search(r'%Warning-(IMPLICIT|PINMISSING|UNDRIVEN|MULTIDRIVEN|LATCH|UNOPTFLAT)\b',build)
        if stage == 'leaf':
            assert [row['label'] for row in rows] == ['controls-quad0','controls-quad1','extents',
                'mutant-u_alias','mutant-v_alias','mutant-fatal','mutant-credit','mutant-request','mutant-pair_credit']
            for row in rows[:2]: assert 'checked=16384 excluded=0' in row['log']
            assert 'checked=1228800' in rows[2]['log']
            for row in rows:
                expected = (gate.extent_fixture(original['ven_axi_master.sv']) if row['label']=='extents'
                    else gate.control_fixture(original['ven_axi_master.sv'],
                        row['label'].removeprefix('mutant-') if row['expected_failure'] else 'none'))
                assert (folder/row['label']/'tb.sv').read_text() == expected
        elif stage == 'cache':
            assert (folder/'miter/tb_l1d_mem_chain.sv').read_text() == gate.cache_fixture()
            assert 'checks=2387 stores=68 pairs=3 load_stores=1 quad=1 blocked=30 idle_credit_changes=0 full_queue=84' in rows[0]['log']
            assert 'PARALLEL-CACHE-MITER checks=4781 next=0' in rows[0]['log']
        elif stage in ('wrapper','corners'):
            expected = gate.wrapper.fixture() if stage=='wrapper' else gate.corners.fixture()
            marker = 'PAIR-CREDIT-'+stage.upper()+'-OK'
            coverage = []
            for row in rows:
                assert (folder/row['label']/'tb_qualified_pair_wrapper.sv').read_text() == expected
                coverage.append(next(line for line in row['log'].splitlines() if line.startswith(marker)))
            assert coverage[0] == coverage[1]
        else:
            assert [row['label'] for row in rows] == [label+suffix for label,_,_,_ in gate.faults.CASES
                                                    for suffix in ('-parent','-candidate')]
            for (label,top,extra,marker), start in zip(gate.faults.CASES,range(0,18,2)):
                for candidate,row in zip((False,True),rows[start:start+2]):
                    expected = gate.fault_fixture((gate.HERE/(top+'.sv')).read_text(),candidate)
                    assert (folder/row['label']/(top+'.sv')).read_text() == expected
                    assert marker in row['log']
                    if candidate: assert ".PARALLEL_WRITE_ADMISSION(1'b1)" in expected
        for name in ('started.json','closed.json'): pins[str(folder/name)] = sha(folder/name)
        runs[stage] = dict(seconds=closed['seconds'],native_runs=len(rows))
    for path in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(gate.__file__).resolve()):
        pins[str(path)] = sha(path)
    assert all(sha(path)==value for path,value in pins.items())
    return dict(passed=True,pins=pins,owners=owners,runs=runs,native_runs=32,
        positive_native_runs=26,required_failing_mutants=6,
        whole_core=False,standard_suite=False,hardware_acceptance=False,
        gameplay_ipc=None,fmax_mhz=None)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    assert root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    out = args.out.resolve()
    assert out.parent == root and not out.exists()
    result = audit(root)
    with out.open('x') as stream: json.dump(result,stream,indent=2)
    print(json.dumps({key:value for key,value in result.items() if key!='pins'},indent=2))
