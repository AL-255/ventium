"""Independently classify the cold-alias failure; never relabel it a pass."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import sys

import prepare_current_u_pair as recipe

REPO = Path(__file__).resolve().parents[2]
DATA = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve()
sys.path[:0] = [str(REPO/'verif/diff'),str(REPO/'verif/sys')]
import tracefmt
import compare
import check_faultlog
spec = importlib.util.spec_from_file_location('audit_native',REPO/'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    root = DATA/'current-u-pair-coldalias-r1'
    started, closed = [json.loads((root/name).read_text()) for name in ('started.json','closed.json')]
    assert not closed['passed'] and closed['pins_unchanged']
    assert len(closed['errors']) == 36
    assert all('A/B state or cycle difference' in e['error'] for e in closed['errors'])
    assert all(sha(p)==h for p,h in started['pins'].items())
    bindings = json.loads(root.with_suffix('.inputs.json').read_text())
    assert all(sha(p)==h for p,h in bindings.items())
    parent, candidate = [DATA/n/'candidate' for n in ('prefix-payload-core-r1','current-u-pair-core-r1')]
    inputs = sorted(p for p in parent.rglob('*') if p.is_file())
    names = [str(p.relative_to(parent)) for p in inputs]
    assert len(names) == 195
    assert names == sorted(str(p.relative_to(candidate)) for p in candidate.rglob('*') if p.is_file())
    assert sorted(n for n in names if sha(parent/n)!=sha(candidate/n)) == sorted(recipe.PARENTS)
    for name in recipe.PARENTS:
        assert (candidate/name).read_text() == recipe.transform((parent/name).read_text(),name)
    owner = dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show','ventium-current-u-pair-coldalias-oct15-r1.service',
        '-pMainPID','-pSubState','-pExecMainStatus','-pInvocationID'],text=True).splitlines())
    assert owner == dict(MainPID='0',SubState='failed',ExecMainStatus='1',InvocationID=started['invocation'])
    rows, records = [], 0
    cases = sorted(p for p in root.iterdir() if p.is_dir())
    assert len(cases) == 36
    for leaf in cases:
        symbols = {p[2]:int(p[0],16) for line in subprocess.check_output(
            ['nm','-n',leaf/'fixture.elf'],text=True).splitlines() if len(p:=line.split())==3 and p[0]!='U'}
        gold = tracefmt.read_trace(str(leaf/'golden.vtrace'))
        traces,counts,first,pairs = {},{},{},{}
        assert json.loads((leaf/'free-qemu.exit.json').read_text())['native_exit']==133
        assert json.loads((leaf/'golden.exit.json').read_text())['native_exit']==0
        for label in ('control','candidate'):
            for mode in ('cycle-func','cycle'):
                stem = label+'-lat0-'+mode
                command = json.loads((leaf/(stem+'.command.json')).read_text())
                assert started['models'][label] in command and '--l1-axi' in command and '--'+mode in command
                assert not any('snapshot' in arg or 'dbg-bp' in arg or 'step' in arg for arg in command)
                assert json.loads((leaf/(stem+'.exit.json')).read_text())['native_exit']==133
                trace = tracefmt.read_trace(str(leaf/(stem+'.vtrace')))
                stdout,stderr = [(leaf/(stem+'.'+ext)).read_text() for ext in ('stdout','stderr')]
                assert not native.FATAL.search(stdout) and not native.FATAL.search(stderr)
                check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()),{})
                clocks = int(re.search(r'after \d+ retired in (\d+) clocks',stderr)[1])
                if mode == 'cycle-func':
                    native.grade_native(trace,stdout,stderr,133,133,2000)
                    output = io.StringIO()
                    assert compare.compare_func(gold,trace,False,0xffffffff,False,20,output,sys_both=True)==0,output.getvalue()
                    counts[label]=clocks
                else:
                    assert clocks==counts[label]
                    events=[r for r in trace.records if int(r['pc'],0)==symbols['hot_load']]
                    assert len(events)==16
                    first[label]={k:events[0][k] for k in ('cyc','pipe','paired')}
                    pairs[label]=sum(r['pipe']=='V' and r['paired'] for r in events)
                traces[label,mode]=trace.records
        assert traces['control','cycle-func']==traces['candidate','cycle-func']
        assert traces['control','cycle']!=traces['candidate','cycle']
        delta=counts['candidate']-counts['control']
        assert delta in (1,3)
        records+=len(traces['candidate','cycle-func'])
        rows.append(dict(case=leaf.name,clocks=counts,extra_cycles=delta,first_v=first,v_pairs=pairs))
    assert {d:sum(r['extra_cycles']==d for r in rows) for d in (1,3)} == {1:18,3:18}
    # Persist the exact evidence used, independently from the failed driver.
    paths=[*inputs,*[candidate/n for n in names],Path(__file__).resolve(),Path(recipe.__file__).resolve(),
           Path(native.__file__),Path(tracefmt.__file__),Path(compare.__file__),Path(check_faultlog.__file__),
           root.with_suffix('.inputs.json')]
    paths += [p for p in root.rglob('*') if p.is_file()]
    result=dict(audit_passed=True,candidate_passed=False,rejected_for_cycle_regression=True,
        cases=36,axi_latency=0,architectural_records=records,complete_qemu_comparisons=72,
        all_functional_states_equal=True,extra_cycles_histogram={'1':18,'3':18},
        first_v_lost_pair=sum(r['first_v']['control']['paired'] and not r['first_v']['candidate']['paired'] for r in rows),
        owner=owner,rows=rows,pins={str(p):sha(p) for p in paths},
        latency7_completed=False,hardware_acceptance=False,standard_suite=False,gameplay_ipc=None)
    with (root/'audit.json').open('x') as stream: json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','pins')}),flush=True)


if __name__=='__main__':main()
