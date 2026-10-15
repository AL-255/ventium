"""Bounded, consistent observation of an owned freshly exec'd native child."""
import os
from pathlib import Path
import time


def retry_owned_observation(child, read_attempt, timeout=3):
    deadline = time.monotonic()+timeout
    errors = []
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError(f'child {child.pid} exited before native observation: {child.returncode}')
        try:
            observed = read_attempt()
            if child.poll() is not None:
                raise RuntimeError(f'child {child.pid} exited during native observation')
            return observed, errors
        except (AssertionError, FileNotFoundError, ProcessLookupError) as error:
            errors.append(repr(error))
            time.sleep(min(.01, max(0, deadline-time.monotonic())))
    raise RuntimeError(f'child {child.pid}: native observation timeout; attempts={errors}')


def observe_owned_native(child, model, argv, bios_dir, cpu, parse_cmdline):
    proc = Path('/proc')/str(child.pid)
    owner_cgroup = Path('/proc/self/cgroup').read_text()
    def starttime():
        return int((proc/'stat').read_text().rsplit(')',1)[1].split()[19])
    def attempt():
        first = starttime()
        observed = dict(pid=child.pid, argv=parse_cmdline((proc/'cmdline').read_bytes()),
            exe=str((proc/'exe').resolve(strict=True)), starttime=first,
            cgroup=(proc/'cgroup').read_text(), affinity=sorted(os.sched_getaffinity(child.pid)),
            bios_dir=bios_dir)
        assert starttime() == first, 'child identity changed during observation'
        assert observed['exe'] == str(model), ('native exe', observed)
        assert observed['argv'] == argv, ('native argv', observed)
        assert observed['affinity'] == [cpu], ('native affinity', observed)
        assert observed['cgroup'] == owner_cgroup, ('native cgroup', observed)
        return observed
    observed, errors = retry_owned_observation(child, attempt)
    observed['admission_retries'] = errors
    return observed
