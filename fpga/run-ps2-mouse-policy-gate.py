#!/usr/bin/env python3
"""Bounded protocol + real-8042 wire check; no Vivado, full guest or board access."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import tempfile
import time


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def kbc_defines(platform_text, definitions):
    """Select the controller's actual feature flags from a frozen FPGA profile.

    Other SoC definitions do not apply to this peripheral-only test. Refuse
    unknown conditional branches rather than silently testing a new default.
    """
    consumed = set(re.findall(r'^\s*`(?:ifdef|ifndef)\s+(\w+)', platform_text, re.M))
    expected = {'VEN_KBC_FAST', 'VEN_KBD_AUTOACK'}
    assert consumed == expected, ('unreviewed 8042 feature flags', consumed)
    tokens = definitions.splitlines()
    assert tokens and len(tokens) == len(set(tokens))
    assert all(re.fullmatch(r'[A-Z][A-Z0-9_]*(?:=[A-Za-z0-9_\x27]+)?', x) for x in tokens)
    values = dict(x.split('=', 1) if '=' in x else (x, None) for x in tokens)
    assert len(values) == len(tokens), 'duplicate define names'
    assert all(name in values and values[name] is None for name in expected), 'FPGA KBC flags absent/valued'
    return sorted(consumed)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--platform-root', type=Path, required=True)
    ap.add_argument('--mailbox', action='store_true', help='exercise retained CSR ownership between policy and serial transport')
    ap.add_argument('--fpga-defines', type=Path,
                    help='pin a frozen defines.txt and exercise its actual 8042 feature flags')
    args = ap.parse_args()
    assert __debug__
    repo = Path(__file__).resolve().parents[1]
    scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch == Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert scratch.stat().st_dev != repo.stat().st_dev
    assert shutil.disk_usage(scratch).free > 2*1024**3
    assert len(os.sched_getaffinity(0)) == 1 and os.environ.get('INVOCATION_ID')
    cg = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().split('::')[1].strip().lstrip('/')
    assert 0 < int((cg/'memory.max').read_text()) <= 512*1024**2
    assert (cg/'memory.swap.max').read_text().strip() == '0'
    assert 0 < int((cg/'pids.max').read_text()) <= 32
    platform = args.platform_root.resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix='ventium-ps2-mouse-policy.', dir=scratch))
    print(root, flush=True)
    source = root/'source'
    source.mkdir()
    inputs = [repo/'fpga/ven_ps2_device.sv', repo/'fpga/tb_ps2_mouse_policy.sv',
              repo/'fpga/board-tools/ven_ps2_mouse.py',
              repo/'fpga/board-tools/test_ven_ps2_mouse.py',
              platform/'soc/ps2.v', platform/'common/simple_fifo.v', Path(__file__)]
    if args.mailbox:
        inputs.append(repo/'fpga/ven_ps2_mailbox.sv')
    if args.fpga_defines:
        inputs.append(args.fpga_defines.resolve(strict=True))
    assert len({p.name for p in inputs}) == len(inputs), 'frozen input basename collision'
    pins = {str(p): sha(p) for p in inputs}
    for p in inputs:
        shutil.copyfile(p, source/p.name)
        assert sha(source/p.name) == pins[str(p)]
        pins[str(source/p.name)] = pins[str(p)]
    definitions = (kbc_defines((source/'ps2.v').read_text(),
                              (source/args.fpga_defines.name).read_text())
                   if args.fpga_defines else [])
    tools = {name: str(Path(shutil.which(name)).resolve(strict=True)) for name in ('iverilog', 'vvp', 'python3')}
    pins.update({p: sha(p) for p in tools.values()})
    spec = importlib.util.spec_from_file_location('mouse_policy_frozen', source/'ven_ps2_mouse.py')
    policy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(policy)
    rows = []

    def save(name, data):
        with (root/name).open('x') as f:
            json.dump(data, f, indent=2)
            f.write('\n')

    def events():
        return dict(x.split() for x in (cg/'memory.events').read_text().splitlines())

    def command(label, argv, *, expected=0, cwd=source):
        start = time.monotonic()
        with (root/(label+'.log')).open('xb') as log:
            run = subprocess.run(argv, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=30)
        rows.append(dict(label=label, argv=argv, exit=run.returncode, seconds=time.monotonic()-start))
        assert run.returncode == expected, (label, run.returncode, expected)
        return (root/(label+'.log')).read_text()

    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'], mailbox=args.mailbox,
                             kbc_defines=definitions,
                             affinity=sorted(os.sched_getaffinity(0)), memory_before=events()))
    failure = None
    try:
        unit = command('unit', [tools['python3'], '-B', '-m', 'unittest', '-v', 'test_ven_ps2_mouse'])
        assert 'Ran 14 tests' in unit and unit.endswith('\nOK\n')
        original = (source/'ven_ps2_mouse.py').read_text()
        mutations = (
            ('resend-byte-only', 'self._queue.append(self._last)',
             'self._queue.append(_Packet(self._last.data[-1:]))',
             'test_resend_whole_packet_and_no_double_motion_consumption'),
            ('consume-motion-twice', 'packet.motion = None  # RESEND',
             'pass  # RESEND', 'test_resend_whole_packet_and_no_double_motion_consumption'),
            ('wrong-y-sign', '(0x20 if sy < 0 else 0)',
             '(0x20 if sy > 0 else 0)', 'test_status_button_mapping_and_packet_signs'),
        )
        for label, before, after, test in mutations:
            assert original.count(before) == 1
            mutant = root/label
            mutant.mkdir()
            (mutant/'ven_ps2_mouse.py').write_text(original.replace(before, after))
            shutil.copyfile(source/'test_ven_ps2_mouse.py', mutant/'test_ven_ps2_mouse.py')
            for p in mutant.iterdir():
                pins[str(p)] = sha(p)
            rejected = command(label, [tools['python3'], '-B', '-m', 'unittest',
                '-v', 'test_ven_ps2_mouse.MouseTests.'+test], expected=1, cwd=mutant)
            assert 'AssertionError' in rejected and 'FAILED (failures=' in rejected
        for hz in (3125000, 40000000):
            label = 'wire-'+str(hz)
            image = root/(label+'.vvp')
            command(label+'-compile', [tools['iverilog'], '-g2012', '-Wall',
                '-s', 'tb_ps2_mouse_policy', '-Ptb_ps2_mouse_policy.HZ='+str(hz), '-o', str(image),
                *['-D'+definition for definition in definitions],
                *(['-DVEN_PS2_MAILBOX', str(source/'ven_ps2_mailbox.sv')] if args.mailbox else []),
                *[str(source/name) for name in ('ven_ps2_device.sv', 'tb_ps2_mouse_policy.sv',
                                                'ps2.v', 'simple_fifo.v')]])
            start = time.monotonic()
            proc = subprocess.Popen([tools['vvp'], str(image)], cwd=root,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            selector = selectors.DefaultSelector()
            selector.register(proc.stdout, selectors.EVENT_READ)
            buffer = b''
            commands = transmitted = 0
            with (root/(label+'.log')).open('xb') as log:
                def line():
                    nonlocal buffer
                    deadline = min(start+120, time.monotonic()+20)
                    while b'\n' not in buffer:
                        remaining = deadline-time.monotonic()
                        if remaining <= 0 or not selector.select(remaining):
                            raise TimeoutError('native wire response deadline')
                        data = os.read(proc.stdout.fileno(), 65536)
                        if not data:
                            raise RuntimeError('native wire EOF before response: '+repr(buffer))
                        log.write(data)
                        log.flush()
                        buffer += data
                    result, buffer = buffer.split(b'\n', 1)
                    return result.decode()

                def request(op, value):
                    proc.stdin.write(f'{op} {value}\n'.encode())
                    proc.stdin.flush()

                mouse = policy.Mouse()

                def drain(expected):
                    nonlocal transmitted
                    result = []
                    while mouse.peek() is not None:
                        assert len(result) < 8
                        token, value = mouse.admitted()
                        request(2, value)
                        assert line() == f'TX {value}'
                        mouse.completed(token, delivered=True)
                        result.append(value)
                        transmitted += 1
                    assert result == expected, (result, expected)

                def host(value, expected):
                    nonlocal commands
                    request(1, value)
                    received = line().split()
                    assert received == ['RX', str(value), '0'], received
                    # Invoke the frozen real policy with the RTL-received byte.
                    mouse.receive(int(received[1]), errors=int(received[2]))
                    drain(expected)
                    commands += 1

                try:
                    native = dict(pid=proc.pid,
                        exe=str((Path('/proc')/str(proc.pid)/'exe').resolve(strict=True)),
                        affinity=sorted(os.sched_getaffinity(proc.pid)),
                        cgroup=(Path('/proc')/str(proc.pid)/'cgroup').read_text())
                    assert native['exe'] == tools['vvp']
                    assert native['affinity'] == sorted(os.sched_getaffinity(0))
                    assert native['cgroup'] == Path('/proc/self/cgroup').read_text()
                    assert line() == f'READY {hz}'
                    drain([0xAA, 0])
                    host(0xFF, [0xFA, 0xAA, 0])
                    host(0xF2, [0xFA, 0])
                    host(0xF3, [0xFA]); host(200, [0xFA])
                    host(0xE8, [0xFA]); host(3, [0xFA])
                    host(0xE9, [0xFA, 0, 3, 200])
                    host(0xF4, [0xFA])
                    mouse.input(20, -12, 1)
                    mouse.advance(5_000_000)
                    drain([0x29, 20, 244])
                    host(0xFE, [0x29, 20, 244])
                    mouse.input(buttons=0)
                    mouse.advance(10_000_000)
                    drain([8, 0, 0])
                    host(0xF0, [0xFA])
                    mouse.input(-128, 255, 6)
                    host(0xEB, [0xFA, 0x1E, 128, 255])
                    host(0xE9, [0xFA, 0x63, 3, 200])
                    host(0xEE, [0xFA]); host(0xA5, [0xA5]); host(0xEC, [0xFA])
                    host(0xF5, [0xFA]); host(0xF6, [0xFA])
                    host(0xE9, [0xFA, 3, 2, 100])
                    host(0xFF, [0xFA, 0xAA, 0])
                    request(3, 0)
                    marker = 'PS2-MOUSE-MAILBOX-WIRE-OK' if args.mailbox else 'PS2-MOUSE-WIRE-OK'
                    assert line() == f'{marker} hz={hz} completed={transmitted}'
                    proc.stdin.close()
                    proc.stdin = None
                    tail = proc.communicate(timeout=5)[0]
                    log.write(tail)
                    status = proc.wait(timeout=5)
                    assert status == 0
                    rows.append(dict(label=label, exit=status, seconds=time.monotonic()-start,
                                     host_commands=commands, delivered_bytes=transmitted,
                                     native=native, child_reaped=True))
                finally:
                    selector.close()
                    if proc.poll() is None:
                        proc.kill()
                    proc.wait(timeout=5)
                    proc.stdout.close()
                    if proc.stdin is not None and not proc.stdin.closed:
                        proc.stdin.close()
    except Exception as error:
        failure = repr(error)
    stable = all(sha(p) == h for p, h in pins.items())
    after = events()
    passed = failure is None and stable and after['oom'] == after['oom_kill'] == '0'
    save('closed.json', dict(passed=passed, error=failure, commands=rows, pins=pins,
        pins_unchanged=stable, memory_after=after, memory_peak=int((cg/'memory.peak').read_text()),
        mailbox=args.mailbox, kbc_defines=definitions,
        integrated_candidate=False, physical_board=False, standard_suite=False, gameplay_ipc=None))
    print(json.dumps(dict(passed=passed, error=failure, evidence=str(root))), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
