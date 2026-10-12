#!/usr/bin/env python3
"""Same-profile cold AGI/reference tests, full QEMU state and exact A/B clocks.

Reuse the original priming microbenchmarks and rejection controls. Their
feature-off/on admission is replaced by strict identical enabled profiles;
their performance comparison is strengthened to complete state/cycle equality.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
FE = REPO/'verif/fe_pipe'
spec = importlib.util.spec_from_file_location('agi_runner', FE/'run-agi-resident-prime.py')
agi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agi)
once = agi.once


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def adapt(original, kind):
    text = agi.transform(original) if kind == 'agi' else original
    feature = 'VEN_RAW_AGI_PRIME' if kind == 'agi' else 'VEN_REF_OPERAND_PRIME'
    text = once(text, "    assert profiles['candidate']==profiles['control']|{'"+feature+"'}",
                "    assert profiles['candidate']==profiles['control']")
    text = once(text, "    assert '"+feature+"' not in profiles['control']",
                "    assert {'VEN_RAW_AGI_PRIME','VEN_REF_OPERAND_PRIME'} <= profiles['control']")
    text = once(text, "                assert a['resident_primes']==0",
                "                assert a['resident_primes']==b['resident_primes'], ('prime event count',case,latency)")
    text = once(text, "assert b['total_clocks']<=a['total_clocks']", "assert b['total_clocks']==a['total_clocks']")
    text = once(text, "assert sum(b['warm_cycles'])<=sum(a['warm_cycles'])", "assert b['warm_cycles']==a['warm_cycles']")
    text = once(text, "        assert any(g['fraction']>0 for g in gains),'no measured clock saving'",
                "        assert all(g['fraction']==0 for g in gains), 'timing cofactor changed guest cycles'")
    text = once(text, "        rows=traces['cycle'].records", """        state_sha=hashlib.sha256(json.dumps(traces['cycle-func'].records,sort_keys=True).encode()).hexdigest()
        cycle_sha=hashlib.sha256(json.dumps(traces['cycle'].records,sort_keys=True).encode()).hexdigest()
        rows=traces['cycle'].records""")
    text = once(text, "return dict(case=case,model=name,latency=latency,records=len(rows),paired_v=len(pairs),",
                "return dict(state_sha256=state_sha,cycle_sha256=cycle_sha,case=case,model=name,latency=latency,records=len(rows),paired_v=len(pairs),")
    text = once(text, "                a=indexed[case,'control',latency];b=indexed[case,'candidate',latency]",
                """                a=indexed[case,'control',latency];b=indexed[case,'candidate',latency]
                assert a['state_sha256']==b['state_sha256'], ('complete architectural A/B',case,latency)
                assert a['cycle_sha256']==b['cycle_sha256'], ('complete cycle A/B',case,latency)""")
    text = once(text, "HERE=Path(__file__).resolve().parent", 'HERE=Path('+repr(str(FE))+')')
    text = once(text, 'max_workers=32', 'max_workers=16')
    # Avoid a second golden thread selecting a just-chosen ephemeral GDB port.
    text = once(text, 'import traceback', 'import traceback\nimport threading\ngolden_lock=threading.Lock()')
    start, end = text.index('        with socket.socket() as sock:'), text.index('        gold=tracefmt.read_trace(')
    block = text[start:end]
    text = text[:start]+'        with golden_lock:\n'+''.join('    '+line+'\n' for line in block.splitlines())+text[end:]
    compile(text, '<same-profile-prime>', 'exec')
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control', 'candidate', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--kind', choices=('agi', 'ref'), required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    root.mkdir()
    source = FE/'run-ref-operand-prime.py'
    runner = root/'run_same_profile.py'
    runner.write_text(adapt(source.read_text(), args.kind))
    pins = {str(p): sha(p) for p in (source, runner, Path(__file__),
            FE/'run-agi-resident-prime.py', FE/'prepare-agi-prime-fixture.py', FE/'ref-operand-prime.S')}
    command = ['python3', '-B', str(runner), '--control', str(args.control.resolve(strict=True)),
               '--candidate', str(args.candidate.resolve(strict=True)), '--out', str(root/'matrix'), '--smoke']
    def save(name, value):
        with (root/name).open('x') as stream:
            json.dump(value, stream, indent=2)
    save('started.json', dict(pins=pins, command=command, invocation=os.environ['INVOCATION_ID'],
                             affinity=sorted(os.sched_getaffinity(0))))
    with (root/'driver.log').open('x') as stream:
        native = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=240)
    result = json.loads((root/'matrix/result.json').read_text())
    unchanged = all(sha(p) == h for p, h in pins.items())
    measurements = result['measurements']
    candidate = [row for row in measurements if row['model'] == 'candidate']
    passed = native.returncode == 0 and result['passed'] and result['inputs_unchanged'] and unchanged
    passed &= len(candidate) == 40 and not result['errors'] and any(row['resident_primes'] for row in candidate)
    save('closed.json', dict(passed=passed, native_exit=native.returncode, pins_unchanged=unchanged,
        fixture_cases=20, candidate_records=sum(row['records'] for row in candidate),
        candidate_primes=sum(row['resident_primes'] for row in candidate),
        paired_v=sum(row['paired_v'] for row in candidate), kind=args.kind,
        errors=result['errors'], standard_suite=False, gameplay_ipc=None, full_matrix=False))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
