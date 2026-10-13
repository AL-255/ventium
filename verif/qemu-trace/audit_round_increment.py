"""Read-only verification of a terminal private SoftFloat event run."""
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess

from run_round_increment import cases, sha


def audit(root,unit):
    start=json.loads((root/'started.json').read_text())
    closed=json.loads((root/'closed.json').read_text())
    owner=dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',unit,'-p','SubState','-p','MainPID',
        '-p','ExecMainStatus','-p','InvocationID'],text=True).splitlines())
    assert owner==dict(SubState='exited',MainPID='0',ExecMainStatus='0',InvocationID=start['invocation'])
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert not any(closed[k] for k in ('architectural_c1','canonical_gate','standard_suite','hardware_acceptance'))
    assert start['affinity']==[12]
    assert all(sha(p)==h for p,h in closed['pins'].items())
    expected=cases()
    saved=json.loads((root/'cases.json').read_text())
    assert json.loads(json.dumps(expected))==saved and len(saved)==start['cases']
    control=None; reports=[]
    assert [r['label'] for r in closed['rows']]==['control','candidate','nonzero-inc','missing-reset']
    for report in closed['rows']:
        label=report['label']; work=root/label
        assert sha(work/'probe')==report['binary_sha256']
        assert sha(work/'stdout')==report['stdout_sha256']
        assert (work/'stderr').read_text()=='' and report['native_exit']==0
        records=[]
        for line in (work/'stdout').read_text().splitlines():
            fields=line.split(); assert len(fields)==4
            records.append(tuple(int(v,16) for v in fields[:3])+(int(fields[3]),))
        assert len(records)==len(saved)==report['records']
        if label=='control':
            control=[r[:3] for r in records]
            assert all(r[3]==-1 for r in records)
        assert [r[:3] for r in records]==control
        mismatches=[i for i,(e,r) in enumerate(zip(saved,records)) if e['expected']!=r[3]]
        assert len(mismatches)==report['event_mismatches']
        if label=='candidate': assert not mismatches
        if label in ('nonzero-inc','missing-reset'): assert mismatches
        compile_pins=json.loads((root/(label+'-compile-inputs.json')).read_text())['pins']
        assert all(closed['pins'][p]==h==sha(p) for p,h in compile_pins.items())
        reports.append(dict(label=label,records=len(records),mismatches=len(mismatches)))
    return dict(passed=True,owner=owner,cases=len(saved),counts_by_operation=dict(Counter(
        r['args'][0] for r in saved)),expected_increments=sum(r['expected'] for r in saved),
        pins=len(closed['pins']),rows=reports,closed_sha256=sha(root/'closed.json'),
        architecture_qualified=False,canonical_oracle_changed=False)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',type=Path,required=True)
    parser.add_argument('--unit',required=True)
    args=parser.parse_args()
    print(json.dumps(audit(args.run.resolve(strict=True),args.unit),indent=2))
