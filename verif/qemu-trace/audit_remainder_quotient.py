"""Read-only independent recheck of a closed private quotient A/B run."""
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess

from run_remainder_quotient import cases, parse, sha


def audit(root, unit):
    started = json.loads((root/'started.json').read_text())
    closed = json.loads((root/'closed.json').read_text())
    owner = dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',unit,'-p','SubState','-p','MainPID',
        '-p','ExecMainStatus','-p','InvocationID'],text=True).splitlines())
    assert owner == dict(SubState='exited',MainPID='0',ExecMainStatus='0',InvocationID=started['invocation'])
    assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
    assert not any(closed[k] for k in ('architectural_helper_qualified','canonical_gate','standard_suite','hardware_acceptance'))
    assert started['affinity'] == [13] and not started['canonical_oracle_changed']
    assert all(sha(p) == h for p,h in closed['pins'].items())
    rows = json.loads((root/'cases.json').read_text())
    assert rows == json.loads(json.dumps(cases())) and len(rows) == started['cases']
    control = None
    summaries = []
    assert [r['label'] for r in closed['rows']] == ['control','candidate','missing-increment','wrong-mode']
    for report in closed['rows']:
        label = report['label']
        work = root/label
        assert sha(work/'probe') == report['binary_sha256']
        assert sha(work/'stdout') == report['stdout_sha256']
        assert not (work/'stderr').read_text() and report['native_exit'] == 0
        records = parse((work/'stdout').read_text())
        assert len(records) == len(rows) == report['records']
        if label == 'control': control = records
        numeric = sum(c[:3] != v[:3] for c,v in zip(control,records))
        quot = sum(r['expected_quotient'] != v[3] for r,v in zip(rows,records))
        trunc = sum(r['args'][0] == 1 and c != v for r,c,v in zip(rows,control,records))
        assert (numeric,quot,trunc) == (report['numeric_exception_mismatches'],
            report['quotient_mismatches'],report['truncation_mismatches'])
        if label == 'candidate':
            assert numeric == quot == 0
            assert all(c[3] != r['expected_quotient'] and v[3] == r['expected_quotient']
                       for r,c,v in zip(rows,control,records) if r['args'][0] == 1 and c != v)
        else: assert quot > 0
        if label == 'wrong-mode': assert numeric > 0
        else: assert numeric == 0
        pins = json.loads((root/(label+'-compile-inputs.json')).read_text())['pins']
        assert all(closed['pins'][p] == h == sha(p) for p,h in pins.items())
        summaries.append(dict(label=label,numeric_exception_mismatches=numeric,
                              quotient_mismatches=quot,truncation_mismatches=trunc))
    return dict(passed=True,owner=owner,cases=len(rows),pins=len(closed['pins']),
        counts_by_kind=dict(Counter(r['args'][0] for r in rows)),rows=summaries,
        closed_sha256=sha(root/'closed.json'),architectural_helper_qualified=False,
        canonical_oracle_changed=False)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run',type=Path,required=True)
    ap.add_argument('--unit',required=True)
    args = ap.parse_args()
    print(json.dumps(audit(args.run.resolve(strict=True),args.unit),indent=2))
