"""Observe exec identity before supplying input to very short native probes."""
import os
from pathlib import Path
import subprocess
import time

from run_small_quotient import sha, save


def execute(label, command, root, stdin=None):
    command = list(map(str,command)); begin = time.monotonic()
    payload = stdin.read_bytes() if stdin else b''
    offset = 0; observed = []; seen = set(); transient_samples = 0
    with (root/(label+'.out')).open('xb') as out, (root/(label+'.err')).open('xb') as err:
        child = subprocess.Popen(command, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
                                 stdout=out, stderr=err)
        if stdin: os.set_blocking(child.stdin.fileno(), False)
        try:
            while child.poll() is None:
                try:
                    proc = Path('/proc')/str(child.pid)
                    argv = proc.joinpath('cmdline').read_bytes().rstrip(b'\0').decode().split('\0')
                    exe = proc.joinpath('exe').resolve()
                    if exe == Path(command[0]).resolve() and argv == command:
                        seen.add(tuple(sorted(os.sched_getaffinity(child.pid))))
                        if not observed:
                            observed.append(dict(exe=str(exe), argv=argv,
                                cgroup=proc.joinpath('cgroup').read_text(),
                                starttime=proc.joinpath('stat').read_text().rsplit(')',1)[1].split()[19]))
                    else: transient_samples += 1
                except (FileNotFoundError,ProcessLookupError): pass
                # Empty /proc cmdline during exec/exit is not identity evidence.
                # Native probes block on input until the exact argv/exe and
                # affinity have been observed; no timing sleep is relied upon.
                if stdin and observed and not child.stdin.closed:
                    try: offset += os.write(child.stdin.fileno(), payload[offset:offset+65536])
                    except BlockingIOError: pass
                    if offset == len(payload): child.stdin.close()
                assert time.monotonic()-begin < 60, label+' timeout'
                time.sleep(.0001)
            code = child.wait()
        finally:
            if child.poll() is None: child.kill()
            child.wait()
            if child.stdin and not child.stdin.closed: child.stdin.close()
    result = dict(label=label, command=command, native_exit=code, pid=child.pid,
        actual_wait=True, reaped=not Path('/proc',str(child.pid)).exists(),
        affinity=sorted(seen), observed=observed, transient_identity_samples=transient_samples,
        input_after_identity=bool(stdin), input_bytes=offset, seconds=time.monotonic()-begin,
        stdout_sha256=sha(root/(label+'.out')))
    save(root/(label+'-native.json'),result)
    assert code == 0 and result['reaped'] and seen == {(12,)} and observed
    assert observed[0]['argv'] == command and offset == len(payload)
    assert observed[0]['cgroup'].strip().endswith('/'+os.environ['UNDERFLOW_OWNER'])
    return result
