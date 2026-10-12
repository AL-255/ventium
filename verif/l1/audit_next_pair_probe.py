"""Audit closed native overlap tests, excluding comparator stdout by identity.

The first collector mistook cycle-func-diff.stdout for model output. Retain its
failed receipt; require every underlying native suite to have passed, then
independently collect only actual simulator invocations. No native failure is
converted into a pass here.
"""
import argparse
from pathlib import Path
import re

from run_next_pair_probe import PATTERN, FIELDS, sha, load, save, stable


def audit(primary, supplement):
    first, extra = load(primary/'closed.json'), load(supplement/'closed.json')
    assert first['pins_unchanged'] and not first['passed']
    assert len(first['errors']) == 1
    assert 'cycle-func-diff.stdout' in first['errors'][0]['error']
    assert 'missing probe final' in first['errors'][0]['error']
    assert [r['label'] for r in first['rows']] == ['load-store','held','branch','integer','fp']
    assert extra['passed'] and extra['pins_unchanged'] and not extra['errors']
    assert [r['label'] for r in extra['rows']] == ['agi','ref','agi-store']
    assert extra['negative']['expected_failure'] and extra['negative']['native_exit'] == 1
    pins = {str(Path(__file__).resolve()):sha(__file__)}
    totals = {k:0 for k in FIELDS}; counts = {}
    for root,summary in ((primary,first),(supplement,extra)):
        pins.update(load(root/'started.json')['pins'])
        for p in (root/'started.json',root/'closed.json'): pins[str(p)] = sha(p)
        for row in summary['rows']:
            label = row['label']; assert row['native_exit'] == 0
            receipt = root/label/('result.json' if label == 'held' else 'closed.json')
            if 'receipt_sha256' in row: assert sha(receipt) == row['receipt_sha256']
            done = load(receipt)
            assert done['passed'] and not done['errors']
            assert done['inputs_unchanged' if label == 'held' else 'pins_unchanged']
            pins[str(receipt)] = sha(receipt)
            count = 0
            for p in (root/label).rglob('candidate*.stdout'):
                if not re.fullmatch(r'candidate-(?:lat|l)\d+-cycle(?:-func)?\.stdout',p.name):
                    continue
                matches = PATTERN.findall(p.read_text()); assert len(matches) == 1,str(p)
                command = load(p.with_suffix('.command.json'))
                assert '--l1-axi' in command and ('--cycle' in command or '--cycle-func' in command)
                assert any(Path(c).name == 'tb_ventium' for c in command)
                numbers = dict(zip(FIELDS,map(int,matches[0])))
                assert numbers['clocks'] > 0 and numbers['retained'] == 0
                for k,v in numbers.items(): totals[k] += v
                for item in (p,p.with_suffix('.command.json')): pins[str(item)] = sha(item)
                count += 1
            counts[label] = count
    assert counts == dict(zip(('load-store','held','branch','integer','fp','agi','ref','agi-store'),
                             (288,96,2560,1024,16,80,80,96))),counts
    assert all(totals[k] > 0 for k in ('agi','ref','prime','intent','request','accept','shape_only'))
    negative = supplement/'shape-only-negative.log'
    assert sha(negative) == extra['negative']['log_sha256']
    assert 'NEXT-PAIR-BROAD: shape-only exclusion loses a real hint' in negative.read_text()
    pins[str(negative)] = sha(negative)
    assert stable(pins)
    return dict(passed=True,pins=pins,pins_unchanged=True,counts=counts,coverage=totals,
                negative=extra['negative'],first_collector_failed=True,
                simulation_only=True,formal_proof=False,hardware_acceptance=False,gameplay_ipc=None)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for k in ('primary','supplement','out'): ap.add_argument('--'+k,type=Path,required=True)
    args = ap.parse_args()
    result = audit(args.primary.resolve(strict=True),args.supplement.resolve(strict=True))
    save(args.out,result)
    print({k:v for k,v in result.items() if k != 'pins'},flush=True)


if __name__ == '__main__': main()
