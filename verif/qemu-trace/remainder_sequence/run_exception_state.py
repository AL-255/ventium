"""Bounded native/private-QEMU complete saved-state exception diagnostic."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

from run_small_quotient import sha, save
import state_vectors as vectors


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for n in ('out', 'build'): ap.add_argument('--'+n, type=Path, required=True)
    args = ap.parse_args(); root = args.out.resolve(); build = args.build.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch and os.sched_getaffinity(0) == {12}
    assert os.environ['INVOCATION_ID'] and shutil.disk_usage(scratch).free > 4*1024**3+32*1024**2
    built = json.loads((build/'closed.json').read_text()); qemu = Path(built['binary'])
    assert built['passed'] and built['pins_unchanged'] and sha(qemu) == built['sha256']
    source = Path(__file__).with_name('state_probe.c')
    pins = {str(p.resolve()): sha(p) for p in (Path(__file__), source, Path(vectors.__file__),
            Path(__file__).with_name('run_small_quotient.py'), build/'closed.json', qemu)}
    rows = vectors.rows(); root.mkdir(); save(root/'cases.json', rows)
    (root/'stdin.bin').write_bytes(b''.join(map(vectors.pack, rows)))
    save(root/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), cases=len(rows), underflow_masked=True))
    result = dict(passed=False, errors=[], executions=[], mismatches=[], native_oracle_errors=[],
        canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    begin = time.monotonic()
    try:
        command = ['gcc', '-m32', '-march=pentium', '-mno-sse', '-O2', '-fno-pic', '-fno-pie',
            '-fno-stack-protector', '-nostdlib', '-static', '-Wl,--build-id=none,-e,_start',
            str(source), '-o', str(root/'probe')]
        with (root/'compile.log').open('x') as f:
            code = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=30).returncode
        save(root/'compile.json', dict(command=command, native_exit=code)); assert code == 0
        outputs = {}
        for name, command in (('native', [root/'probe']), ('qemu', [qemu, '-cpu', 'pentium', root/'probe'])):
            with (root/'stdin.bin').open('rb') as inp, (root/(name+'.bin')).open('xb') as out, \
                    (root/(name+'.stderr')).open('x') as err:
                child = subprocess.Popen(command, stdin=inp, stdout=out, stderr=err)
                start = time.monotonic(); observed = set()
                try:
                    while child.poll() is None:
                        try: observed.add(tuple(sorted(os.sched_getaffinity(child.pid))))
                        except ProcessLookupError: pass
                        assert time.monotonic()-start < 60, name+' timeout'
                        time.sleep(.0001)
                    code = child.wait()
                finally:
                    if child.poll() is None: child.kill()
                    child.wait()
            raw = (root/(name+'.bin')).read_bytes()
            result['executions'].append(dict(name=name, command=list(map(str, command)),
                native_exit=code, bytes=len(raw), affinity=sorted(observed), sha256=sha(root/(name+'.bin'))))
            assert code == 0 and len(raw) == len(rows)*108 and observed == {(12,)}
            outputs[name] = [raw[i:i+108] for i in range(0, len(raw), 108)]
        for i, (r, n, q) in enumerate(zip(rows, outputs['native'], outputs['qemu'])):
            errors = vectors.check_native(r, n)
            if errors: result['native_oracle_errors'].append(dict(index=i, errors=errors))
            errors = vectors.compare(r, n, q)
            if errors: result['mismatches'].append(dict(index=i, errors=errors))
        result['passed'] = not result['mismatches'] and not result['native_oracle_errors']
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(cases=len(rows), seconds=time.monotonic()-begin,
        pins_unchanged=all(sha(p) == h for p, h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json', result)
    print(json.dumps({**result, 'mismatches': len(result['mismatches']),
                      'native_oracle_errors': result['native_oracle_errors'][:10]}, indent=2), flush=True)
    return int(not result['passed'])


if __name__ == '__main__': raise SystemExit(main())
