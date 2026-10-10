#!/usr/bin/env python3
"""Bounded cold SoC CoreMark seed; require real duration, CRCs and native closure.

Launch with explicit taskset in a retained systemd user service. This checks
one suite component only; it never claims FPGA or whole-suite qualification.
The guest algorithm/port is not changed and no checkpoint is accepted.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import time

from check_result import check

HERE = Path(__file__).resolve().parent


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(path, data):
    with path.open('x') as f:
        json.dump(data, f, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--soc', type=Path, required=True)
    ap.add_argument('--media', type=Path, required=True)
    ap.add_argument('--rom', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--seed', choices=('performance', 'validation'), required=True)
    ap.add_argument('--cpu', type=int, required=True)
    ap.add_argument('--seconds', type=int, default=3600)
    args = ap.parse_args()
    assert __debug__ and 1 <= args.seconds <= 3600
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
    root = args.out.resolve()
    assert root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert shutil.disk_usage(scratch).free > 2*1024**3
    assert os.sched_getaffinity(0) == {args.cpu}
    invocation = os.environ.get('INVOCATION_ID', '')
    assert re.fullmatch('[0-9a-f]{32}', invocation)
    soc, media, rom = (p.resolve(strict=True) for p in (args.soc, args.media, args.rom))
    model = soc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted'
    built = json.loads((soc/'build-closed.json').read_text())
    assert built['passed'] and built['inputs_unchanged'] and built['native_exit'] == 0
    assert sha(model) == built['binary_sha256']
    disk = media/'build'/args.seed/'coremark.img'
    prepared = json.loads((media/'closed.json').read_text())
    ref = json.loads((media/'build'/args.seed/'reference.json').read_text())
    assert prepared['passed'] and ref['native_exit'] == 33 and ref['iterations'] == 900
    assert ref in prepared['rows'] and sha(disk) == ref['disk_sha256']
    assert sha(media/'build'/args.seed/'qemu-debug.log') == ref['log_sha256']
    pins = dict(json.loads((soc/'build-started.json').read_text())['pins'])
    pins.update(prepared['pins'])
    for p in (Path(__file__), HERE/'check_result.py', soc/'build-closed.json',
              soc/'defines.txt', model, media/'closed.json', disk,
              media/'build'/args.seed/'reference.json',
              media/'build'/args.seed/'qemu-debug.log', rom/'boot0.rom', rom/'boot1.rom'):
        pins[str(p)] = sha(p)
    assert all(sha(p) == h for p,h in pins.items())
    defs = set((soc/'defines.txt').read_text().split())
    assert {'VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_L1_AXI'} <= defs
    assert not {'VEN_UOPCACHE','VEN_SYS_FASTPATH_ALL'} & defs
    assert re.search(r"\.cycle_mode\s*\(1'b1\)",
                     (soc/'source/ao486-sim/ven/ven_ao486_shim.sv').read_text())
    root.mkdir()
    shutil.copytree(rom, root/'rom')
    shutil.copyfile(disk, root/'coremark.img')
    stop = root/'stop.request'
    argv = [str(model),'--ide',str(root/'coremark.img'),'--rate','40000000',
            '--rate-rtc','40000000','--rate-vga','80000000','--mem','16',
            '--cycles','450000000','--ven-perf-every','1000000',
            '--vgatext-every','1000000','--stop-request',str(stop)]
    env = {k:v for k,v in os.environ.items()
           if not k.startswith(('VEN_','VTM_','AO486_','AXI_','TB_'))}
    env.update(AO486_BIOS_DIR=str(root/'rom'), TMPDIR=str(root))
    cg = Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    limits = {p:(cg/p).read_text() for p in ('memory.max','memory.swap.max','pids.max','cpu.max')}
    assert int(limits['memory.max']) <= 2*1024**3 and limits['memory.swap.max'].strip() == '0'
    quota,period = limits['cpu.max'].split()
    assert quota.isdecimal() and 0 < int(quota) <= int(period)
    save(root/'started.json', dict(pins=pins, argv=argv, seed=args.seed, reference=ref,
        model_sha256=sha(model), cpu=args.cpu, invocation=invocation, limits=limits,
        cold_reset=True, snapshots=False, guest_modifications=False,
        wall_seconds_cap=args.seconds, standard_suite=False, physical_board=False))
    child = subprocess.Popen(argv, cwd=root, env=env, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, start_new_session=True)
    start = time.monotonic()
    proc = Path('/proc')/str(child.pid)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    error = None
    screen, complete = [], []
    pending = b''
    captured = 0
    observed_sha = hashlib.sha256()
    last_u = last_v = 0
    eof = False
    result = None
    native = None

    def line(s):
        nonlocal screen, result, last_u, last_v
        if re.search(r'cannot open|%Error|%Fatal|Assertion failed|CPU HUNG|UNIMPLEMENTED|HOST-STOP-ERROR', s):
            raise RuntimeError(s)
        if s.startswith('[VGATEXT @'):
            screen = []
        elif s.startswith('  |'):
            screen.append(s[3:])
            if s[3:] == 'PORT-END':
                text = '\n'.join(screen)
                checked = check(text, reference_crcs=ref['crcs'], iterations=900,
                                require_valid_duration=True)
                assert not complete or text == complete[0], 'completed console changed'
                complete.append(text)
                result = checked
                if not stop.exists():
                    # This is a host stop request AFTER a complete validated
                    # guest result, never a fabricated guest completion marker.
                    with stop.open('x'): pass
        m = re.match(r'\[VEN-PERF\] cycle=\d+ retires=\d+ clocks=\d+ u=(\d+) v=(\d+)', s)
        if m:
            last_u, last_v = map(int, m.groups())

    try:
        deadline = time.monotonic()+3
        while (proc/'exe').resolve() != model:
            assert child.poll() is None and time.monotonic() < deadline
            time.sleep(0.01)
        native = dict(pid=child.pid, exe=str((proc/'exe').resolve()),
            argv=(proc/'cmdline').read_bytes().rstrip(b'\0').decode().split('\0'),
            affinity=sorted(os.sched_getaffinity(child.pid)), cgroup=(proc/'cgroup').read_text(),
            starttime=int((proc/'stat').read_text().rsplit(')',1)[1].split()[19]))
        assert native['argv'] == argv and native['affinity'] == [args.cpu]
        assert native['cgroup'] == Path('/proc/self/cgroup').read_text()
        save(root/'native.json', native)
        with (root/'run.log').open('xb') as log:
            while not eof:
                if time.monotonic()-start > args.seconds:
                    raise TimeoutError('seed exceeded wall cap')
                if shutil.disk_usage(root).free < 2*1024**3:
                    raise RuntimeError('external disk reserve')
                for key,_ in selector.select(timeout=1):
                    chunk = os.read(key.fileobj.fileno(),65536)
                    if not chunk:
                        eof = True
                        break
                    captured += len(chunk)
                    assert captured <= 16*1024**2, 'log cap'
                    log.write(chunk)
                    log.flush()
                    observed_sha.update(chunk)
                    pending += chunk
                    parts = pending.split(b'\n')
                    pending = parts.pop()
                    assert len(pending) < 1024**2
                    for raw in parts: line(raw.decode('utf-8', errors='strict'))
        assert not pending
        assert child.wait(timeout=5) == 0 and complete and last_v > 0
        assert sha(root/'coremark.img') == ref['disk_sha256']
        assert all(sha(root/'rom'/n) == sha(rom/n) for n in ('boot0.rom','boot1.rom'))
        assert sha(root/'run.log') == observed_sha.hexdigest()
    except BaseException as exc:
        error = repr(exc)
    finally:
        if child.poll() is None:
            os.killpg(child.pid,signal.SIGTERM)
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL)
                child.wait()
        selector.close()
        child.stdout.close()
    events = dict(s.split() for s in (cg/'memory.events').read_text().splitlines())
    stable = all(sha(p) == h for p,h in pins.items())
    reaped = not proc.exists()
    passed = error is None and stable and eof and reaped and child.returncode == 0 and events['oom'] == events['oom_kill'] == '0'
    save(root/'closed.json', dict(passed=passed, error=error, result=result,
        seed=args.seed, native=native, native_exit=child.returncode, invocation=invocation,
        seconds=time.monotonic()-start, pipe_eof=eof, captured_bytes=captured,
        captured_sha256=observed_sha.hexdigest(), pins_unchanged=stable, memory_events=events,
        all_children_reaped=reaped, last_u=last_u, last_v=last_v,
        standard_suite=False, suite_component='CoreMark one seed only', physical_board=False,
        gameplay_ipc=None))
    print(json.dumps(dict(passed=passed,error=error,result=result)),flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
