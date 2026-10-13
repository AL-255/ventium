"""Complete, unmasked cold-core trace comparison using the repaired reference."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO/'verif/diff'))
import tracefmt


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, d):
    with p.open('x') as f:
        json.dump(d, f, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for n in ('build', 'probe', 'out'):
        ap.add_argument('--'+n, type=Path, required=True)
    a = ap.parse_args(); root = a.out.resolve(); build = a.build.resolve(strict=True)
    probe = a.probe.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and os.sched_getaffinity(0) == {13}
    assert os.environ['INVOCATION_ID'] and shutil.disk_usage(scratch).free > 4*1024**3 + 40*1024**2
    old = scratch/'ventium-frndint.tM8XCg6d/integrated-r2'
    audit = json.loads((old/'audit.json').read_text())
    assert audit['passed'] and audit['cold_core_cases'] == 412
    assert all(sha(p) == h for p,h in audit['artifacts'].items())
    built = json.loads((build/'closed.json').read_text())
    tested = json.loads((probe/'closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and tested['passed'] and tested['pins_unchanged']
    qemu = Path(built['binary']); assert sha(qemu) == built['sha256']
    producer = REPO/'verif/qemu-trace/gen_trace.py'; comparator = REPO/'verif/diff/compare.py'
    pins = dict(audit['artifacts'])
    for p in (Path(__file__), old/'audit.json', qemu, build/'closed.json', probe/'closed.json',
              producer, comparator, REPO/'verif/diff/tracefmt.py'):
        pins[str(p)] = sha(p)
    root.mkdir(); save(root/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        model='2050b71430b39fc5059a8f2be6beeae74e232b279d21b2b0541a1e16b7d35d63',
        reused_closed_rtl_trace=str(old/'repaired.vtrace'), no_trace_masks=True))
    rows = []; start = time.monotonic()
    for label, command, env in (
        ('native', [str(old/'test.elf')], dict(os.environ)),
        ('guest', [str(qemu), '-cpu', 'pentium', str(old/'test.elf')], dict(os.environ)),
        ('trace', [sys.executable, '-B', str(producer), '--qemu', str(qemu),
            '--elf', str(old/'test.elf'), '--out', str(root/'qemu.vtrace'),
            '--max-insn', '50000', '--port', '42493', '--x87'],
            dict(os.environ, VTM_QEMU_GDB_PREEXIT='1', TMPDIR=str(root))),
        ('compare', [sys.executable, '-B', str(comparator), '--mode', 'func',
            str(root/'qemu.vtrace'), str(old/'repaired.vtrace')], dict(os.environ))):
        with (root/(label+'.log')).open('x') as f:
            done = subprocess.run(command, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=120)
        rows.append(dict(label=label, command=command, native_exit=done.returncode))
    records = tracefmt.read_trace(str(root/'qemu.vtrace')).records
    last = records[-1]
    passed = all(r['native_exit'] == 0 for r in rows) and len(records) == 11129
    passed &= int(last['ebx'], 16) == 0 and int(last['ebp'], 16) == 412
    stable = all(sha(p) == h for p,h in pins.items())
    result = dict(passed=passed and stable, rows=rows, records=len(records),
        guest_exit=int(last['ebx'], 16), completed_cases=int(last['ebp'], 16),
        seconds=time.monotonic()-start, pins_unchanged=stable,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    save(root/'closed.json', result); print(json.dumps(result, indent=2))
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
