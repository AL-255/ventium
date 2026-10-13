"""Repeat the unchanged leaf with actual native child affinity/closure records.

R1 recorded the taskset-constrained controller, not each native child. Retain
that run; this wrapper changes observation only, not fixtures or comparisons.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
from types import SimpleNamespace

SOURCE = Path(__file__).with_name('run_v_load_payload_leaf.py')
SOURCE_SHA = '1d3a7de9ab18d5c4db26f092ec94de64830b47be9a1ad06d262f3767121e6fe4'


def observed_run(command, stream, env, receipt):
    # command = timeout + its three options + the native executable/arguments.
    expected = Path(shutil.which(command[4])).resolve(strict=True)
    group_text = Path('/proc/self/cgroup').read_text()
    group = Path('/sys/fs/cgroup')/group_text.split('::', 1)[1].strip().lstrip('/')
    seen = {}
    start = time.monotonic()
    child = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                             env=env, start_new_session=True)
    failure = None
    try:
        while child.poll() is None:
            for pid in (group/'cgroup.procs').read_text().split():
                try:
                    proc = Path('/proc')/pid
                    if (proc/'exe').resolve(strict=True) != expected:
                        continue
                    actual = dict(pid=int(pid), exe=str(expected),
                        affinity=sorted(os.sched_getaffinity(int(pid))),
                        argv=[os.fsdecode(v) for v in (proc/'cmdline').read_bytes().split(b'\0')[:-1]],
                        cgroup=(proc/'cgroup').read_text(),
                        starttime=(proc/'stat').read_text().rsplit(')', 1)[1].split()[19])
                except (FileNotFoundError, ProcessLookupError):
                    continue
                assert actual['affinity'] == [18] and actual['cgroup'] == group_text, actual
                seen[(pid, actual['starttime'])] = actual
            if time.monotonic()-start > 25:
                raise TimeoutError('outer native observation timeout')
            time.sleep(.001)
        child.wait()
        assert seen, 'native executable finished without observed affinity: '+str(expected)
    except BaseException as exc:
        failure = repr(exc)
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
        child.wait()
        reaped = not (Path('/proc')/str(child.pid)).exists()
        with receipt.open('x') as output:
            json.dump(dict(native_exit=child.returncode, native=list(seen.values()),
                launcher_pid=child.pid, launcher_reaped=reaped, error=failure,
                seconds=time.monotonic()-start), output, indent=2)
    assert not failure and reaped, failure
    return SimpleNamespace(returncode=child.returncode)


def derive():
    source = SOURCE.read_text()
    assert hashlib.sha256(source.encode()).hexdigest() == SOURCE_SHA
    old = 'result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=25, env=env)'
    new = "result = observed_run(command, stream, env, out/(label+'.native.json'))"
    assert source.count(old) == 1
    source = source.replace(old, new)
    old = 'pins = {str(p): sha(p) for p in inputs}'
    assert source.count(old) == 1
    source = source.replace(old, 'inputs.append(SOURCE)\n    '+old)
    ast.parse(source)
    return source


if __name__ == '__main__':
    exec(compile(derive(), str(__file__), 'exec'), globals())
