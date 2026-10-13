"""Native/exact FRNDINT checks and unchanged adjacent-instruction controls."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO/'verif/sys/frndint'))
import vectors


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, data):
    with p.open('x') as f:
        json.dump(data, f, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for n in ('build', 'out'):
        ap.add_argument('--'+n, type=Path, required=True)
    a = ap.parse_args(); root = a.out.resolve(); build = a.build.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and os.sched_getaffinity(0) == {12}
    assert os.environ['INVOCATION_ID'] and shutil.disk_usage(scratch).free > 4*1024**3 + 32*1024**2
    closed = json.loads((build/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged']
    candidate = Path(closed['binary']); assert sha(candidate) == closed['sha256']
    control = scratch/'ventium-qemu-c1.Mw2HgVmG/build-r1/build/qemu-i386'
    assert sha(control) == '01510a0f2592ab0f21306596a70160b3f31b6fbc0f8a0952dcf5bc322021c8e4'
    native_source = REPO/'verif/sys/frndint/native.c'
    rows = vectors.rows(); data = b''.join(vectors.pack(r) for r in rows)
    root.mkdir(); save(root/'cases.json', rows); (root/'stdin.bin').write_bytes(data)
    pins = {str(p):sha(p) for p in (Path(__file__), Path(vectors.__file__), native_source,
                                   candidate, control, build/'closed.json')}
    save(root/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'], cases=len(rows)))
    command = ['gcc', '-m32', '-march=pentium', '-mno-sse', '-O2', '-fno-pic', '-fno-pie',
               '-fno-stack-protector', '-nostdlib', '-static', '-Wl,--build-id=none,-e,_start',
               str(native_source), '-o', str(root/'native')]
    with (root/'compile.log').open('x') as f:
        code = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=30).returncode
    save(root/'compile.json', dict(command=command, native_exit=code)); assert code == 0
    values = {}; executions = []; begin = time.monotonic()
    for label, command in (('native', [str(root/'native')]),
                          ('control', [str(control), '-cpu', 'pentium', str(root/'native')]),
                          ('candidate', [str(candidate), '-cpu', 'pentium', str(root/'native')])):
        with (root/'stdin.bin').open('rb') as inp, (root/(label+'.bin')).open('xb') as out, (root/(label+'.stderr')).open('x') as err:
            child = subprocess.Popen(command, stdin=inp, stdout=out, stderr=err)
            observed = []; start = time.monotonic()
            while child.poll() is None:
                try: observed.append(sorted(os.sched_getaffinity(child.pid)))
                except ProcessLookupError: pass
                if time.monotonic()-start > 90:
                    child.kill(); child.wait(); raise TimeoutError(label)
                time.sleep(.001)
            code = child.wait()
        raw = (root/(label+'.bin')).read_bytes()
        assert code == 0 and len(raw) == 16*len(rows)
        assert observed and all(x == [12] for x in observed)
        values[label] = list(struct.iter_unpack('<4I', raw))
        executions.append(dict(label=label, command=command, native_exit=code,
            affinity=[12], affinity_observed=True, records=len(rows), stdout_sha256=sha(root/(label+'.bin'))))
    exact = 0
    for row, value in zip(rows, values['native']):
        expected = vectors.finite_result(row)
        if expected is not None:
            number, flags = expected
            assert value[0]|value[1]<<32|value[2]<<64 == number
            assert (value[3] ^ flags) & 0x82ff == 0
            exact += 1
    failures = {}
    for label in ('control', 'candidate'):
        groups = dict(numeric=[], status=[], c1=[], exception=[])
        for i, (row, actual, wanted) in enumerate(zip(rows, values[label], values['native'])):
            if row['kind']: continue
            if actual[:3] != wanted[:3]: groups['numeric'].append(i)
            diff = actual[3] ^ wanted[3]
            for name, mask in (('status', 0x82ff), ('c1', 0x200), ('exception', 0x80ff)):
                if diff & mask: groups[name].append(i)
        failures[label] = groups
    unchanged = [i for i,row in enumerate(rows) if row['kind'] and values['control'][i] != values['candidate'][i]]
    stable = all(sha(p) == h for p,h in pins.items())
    result = dict(passed=stable and not any(failures['candidate'].values()) and not unchanged,
        executions=executions, cases=len(rows), frndint_cases=sum(not r['kind'] for r in rows),
        exact_oracle_cases=exact, failures=failures, changed_control_indices=unchanged,
        pins_unchanged=stable, seconds=time.monotonic()-begin,
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    save(root/'closed.json', result)
    print(json.dumps({**result, 'failures':{n:{k:len(v) for k,v in g.items()} for n,g in failures.items()}}, indent=2))
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
