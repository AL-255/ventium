"""Fresh current-candidate functional replay; not canonical-oracle promotion.

Reuse the exact existing worker/comparator and its qualified private reference.
Only the model identity, repository location and disjoint CPU assignment change.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import prepare_v_result_carry as recipe

REPO = Path(__file__).resolve().parents[2]
MODEL = 'a8e5d55b7704f2449002c71af8db1c5c2fe7ae908669fc5dbf2e663d3a59ff73'
PARENT = 'c9e4b9f86ad080f72ffd8ecef3d4ffc73eb1ecb8574ba7cd185bcae4fa3a643a'
REFERENCE = '998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85'
SOURCE = REPO/'verif/qemu-trace/c1_reference/run_func.py'
SOURCE_SHA = '9e5e78a4f70e1fff7a2894cda8d7d3ba6dc0cc2006400f7a958b1f4cdc98062f'


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def derive(original):
    assert hashlib.sha256(original.encode()).hexdigest() == SOURCE_SHA
    changes = [
        ('REPO=Path(__file__).resolve().parents[3]', 'REPO=Path('+repr(str(REPO))+')'),
        ('369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150', MODEL),
        ('set(range(8,12))', 'set(range(12,16))'),
        ('cpu=8+index%4', 'cpu=12+index%4'),
    ]
    text = original
    for old, new in changes:
        assert text.count(old) == 1
        text = text.replace(old, new)
    recovered = text
    for old, new in reversed(changes):
        assert recovered.count(new) == 1
        recovered = recovered.replace(new, old)
    assert recovered == original
    compile(text, str(SOURCE), 'exec')
    return text, changes


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for n in ('core', 'out'):
        ap.add_argument('--'+n, type=Path, required=True)
    args = ap.parse_args()
    core, out = args.core.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert os.sched_getaffinity(0) == set(range(12,16)) and os.environ['INVOCATION_ID']
    start, done = [json.loads((core/n).read_text()) for n in ('build-started.json', 'build-closed.json')]
    parent = Path(start['parent'])
    assert done['passed'] and done['native_exit'] == 0 and done['pins_unchanged']
    assert sha(core/'obj/tb_ventium') == done['binary_sha256'] == MODEL
    assert sha(parent/'obj/tb_ventium') == start['parent_model'] == PARENT
    assert start['changes'] == sorted(recipe.HASHES) and len(start['definitions']) == 153
    assert start['definitions'] == json.loads((parent/'build-started.json').read_text())['definitions']
    for n in recipe.HASHES:
        assert recipe.transform((parent/'candidate'/n).read_text(), n) == (core/'candidate'/n).read_text()
    assert all(sha(p) == h for p, h in start['pins'].items())
    evidence = scratch/'ventium-fprem-sequence.iSZ9BAj4'
    build, probe = evidence/'build-underflow-r1', evidence/'srt-underflow-r2'
    assert sha(build/'build/qemu-i386') == REFERENCE
    text, changes = derive(SOURCE.read_text())
    driver = out.with_suffix('.driver.py')
    with driver.open('x') as f:
        f.write(text)
    pins = {str(p.resolve()): sha(p) for p in (Path(__file__), Path(recipe.__file__), SOURCE,
        driver, core/'build-started.json', core/'build-closed.json', core/'obj/tb_ventium')}
    command = list(map(str, [sys.executable, '-B', driver, '--core', core, '--out', out,
                            '--build', build, '--probe', probe]))
    with out.with_suffix('.driver.json').open('x') as f:
        json.dump(dict(pins=pins, substitutions=changes, command=command,
            comparison_policy_unchanged=True, canonical_gate_passed=False), f, indent=2)
    code = subprocess.run(command, timeout=600).returncode
    stable = all(sha(p) == h for p, h in pins.items())
    with out.with_suffix('.driver-closed.json').open('x') as f:
        json.dump(dict(native_exit=code, pins_unchanged=stable), f, indent=2)
    assert stable
    return code


if __name__ == '__main__':
    raise SystemExit(main())
