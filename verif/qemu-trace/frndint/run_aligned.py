"""Cold differential run with identical initial ESP, not edited trace fields."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
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
    assert os.environ['INVOCATION_ID'] and shutil.disk_usage(scratch).free > 4*1024**3 + 60*1024**2
    old = scratch/'ventium-frndint.tM8XCg6d/integrated-r2'
    core = scratch/'ventium-frndint.tM8XCg6d/core-r1'
    audit = json.loads((old/'audit.json').read_text())
    assert audit['passed'] and audit['cold_core_cases'] == 412
    assert all(sha(p) == h for p,h in audit['artifacts'].items())
    built = json.loads((build/'closed.json').read_text())
    tested = json.loads((probe/'closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and tested['passed'] and tested['pins_unchanged']
    qemu = Path(built['binary']); assert sha(qemu) == built['sha256']
    model = core/'obj/tb_ventium'
    assert sha(model) == '2050b71430b39fc5059a8f2be6beeae74e232b279d21b2b0541a1e16b7d35d63'
    producer = REPO/'verif/qemu-trace/gen_trace.py'; comparator = REPO/'verif/diff/compare.py'
    pins = dict(audit['artifacts'])
    for p in (Path(__file__), old/'audit.json', model, qemu, build/'closed.json', probe/'closed.json',
              core/'build-closed.json', producer, comparator, REPO/'verif/diff/tracefmt.py'):
        pins[str(p)] = sha(p)
    root.mkdir(); save(root/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        model=sha(model), cold=True, no_trace_masks=True))
    rows = []; begin = time.monotonic()
    def run(label, command, env):
        with (root/(label+'.log')).open('x') as f:
            child = subprocess.Popen(command, env=env, stdout=f, stderr=subprocess.STDOUT)
            observed = []; start = time.monotonic()
            while child.poll() is None:
                try: observed.append(sorted(os.sched_getaffinity(child.pid)))
                except ProcessLookupError: pass
                if time.monotonic()-start > 120:
                    child.kill(); child.wait(); raise TimeoutError(label)
                time.sleep(.001)
            code = child.wait()
        assert observed and all(x == [13] for x in observed)
        rows.append(dict(label=label, command=command, native_exit=code, observed_affinity=[13]))
        return code
    native = run('native', [str(old/'test.elf')], dict(os.environ))
    guest = run('guest', [str(qemu), '-cpu', 'pentium', str(old/'test.elf')], dict(os.environ))
    code = run('trace', [sys.executable, '-B', str(producer), '--qemu', str(qemu),
        '--elf', str(old/'test.elf'), '--out', str(root/'qemu.vtrace'),
        '--max-insn', '50000', '--port', '42494', '--x87'],
        dict(os.environ, VTM_QEMU_GDB_PREEXIT='1', TMPDIR=str(root)))
    assert code == 0
    qt = tracefmt.read_trace(str(root/'qemu.vtrace')).records
    # The first instruction is XOR EBP,EBP: it cannot change ESP. Match the
    # loader's initial stack just as the standard functional worker does.
    assert qt[0]['pc'] == '0x08048000' and qt[0]['bytes'].startswith('31ed')
    esp = qt[0]['esp']
    flatten = json.loads((old/'flatten.json').read_text())
    fields = dict(line.split('=', 1) for line in flatten['stdout'].splitlines())
    rtl = run('rtl', [str(model), '--image', str(old/'test.flat'), '--load', fields['load_addr'],
        '--entry', fields['entry'], '--init-esp', esp, '--out', str(root/'rtl.vtrace'),
        '--max-insn', '50000', '--max-cycles', '2000000', '--x87', '--cycle-func', '--l1-axi'],
        dict(os.environ, AXI_RLAT='7', AXI_WLAT='7'))
    diff = run('compare', [sys.executable, '-B', str(comparator), '--mode', 'func',
        str(root/'qemu.vtrace'), str(root/'rtl.vtrace')], dict(os.environ))
    rt = tracefmt.read_trace(str(root/'rtl.vtrace')).records
    log = (root/'rtl.log').read_text()
    paired = int(re.search(r'pairedV=(\d+)', log).group(1))
    passed = native == guest == rtl == diff == 0 and len(qt) == len(rt) == 11129
    passed &= all(int(t[-1]['ebx'], 16) == 0 and int(t[-1]['ebp'], 16) == 412 for t in (qt, rt))
    passed &= paired > 0 and '--l1-axi selected' in log and '--max-cycles (' not in log and '--max-insn (' not in log
    stable = all(sha(p) == h for p,h in pins.items())
    result = dict(passed=passed and stable, rows=rows, qemu_records=len(qt), rtl_records=len(rt),
        completed_cases=int(rt[-1]['ebp'], 16), actual_v_retirements=paired, initial_esp=esp,
        seconds=time.monotonic()-begin, pins_unchanged=stable,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    save(root/'closed.json', result); print(json.dumps(result, indent=2))
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
