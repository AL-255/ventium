"""Bounded native transport qualification. Creates only a fresh output folder.

Old producer is loaded from pinned git, not reconstructed or edited. Collision
victims are this driver's own QEMU children, verified by listening socket inode.
No listener belonging to another user application is contacted or terminated.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import types

import gen_trace as new

REPO = Path(__file__).resolve().parents[2]
OLD_SHA = 'd17880e1ea030adf66b3e2b208489efe991f68171e75b837238808a965c8ec18'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def unused_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def result_signature(result):
    # StopReply is a plain class with identity equality, not a dataclass. Compare
    # semantic exit fields, never object identity across two producer modules.
    return tuple((value.kind, value.signal, value.exit_code)
                 if hasattr(value, 'raw') else value for value in result)


def wait_owned_listener(proc, port):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        assert proc.poll() is None, 'victim failed to start; do not contact port'
        inodes = set()
        for fd in Path(f'/proc/{proc.pid}/fd').iterdir():
            try:
                link = os.readlink(fd)
            except FileNotFoundError:
                continue
            if link.startswith('socket:['):
                inodes.add(link[8:-1])
        for line in Path(f'/proc/{proc.pid}/net/tcp').read_text().splitlines()[1:]:
            fields = line.split()
            if int(fields[1].split(':')[1], 16) == port and fields[3] == '0A':
                if fields[9] in inodes:
                    return
        time.sleep(.01)
    raise AssertionError('no verified owned listener')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--qemu', type=Path, required=True)
    parser.add_argument('--system-qemu', type=Path, required=True)
    parser.add_argument('--bios', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    scratch = Path(os.environ['TMPDIR']).resolve()
    assert out.is_relative_to(scratch) and not out.exists()
    out.mkdir()
    old_text = subprocess.check_output(
        ['git', 'show', '9fa5578f:verif/qemu-trace/gen_trace.py'], cwd=REPO, text=True)
    assert hashlib.sha256(old_text.encode()).hexdigest() == OLD_SHA
    old = types.ModuleType('old_gen_trace')
    old.__file__ = new.__file__
    exec(compile(old_text, new.__file__, 'exec'), old.__dict__)
    started = time.monotonic()
    pins = {str(p): sha(p) for p in (Path(__file__), Path(new.__file__),
            Path(new.__file__).with_name('owned_gdb.py'), args.qemu,
            args.system_qemu, args.bios, Path(new.__file__).with_name('t_owned_gdb.S'))}
    report = dict(pins=pins, old_producer_sha256=OLD_SHA, checks=[])
    (out/'started.json').write_text(json.dumps(report, indent=2)+'\n')
    checks = report['checks']
    try:
        for name, defines in (('target', []), ('victim', ['-DVICTIM'])):
            command = ['gcc', '-m32', '-nostdlib', '-static', '-no-pie',
                       '-Wl,--build-id=none', *defines,
                       str(Path(__file__).with_name('t_owned_gdb.S')),
                       '-o', str(out/(name+'.elf'))]
            with (out/(name+'.build.log')).open('w') as log:
                subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT,
                               timeout=30)
        target = str(out/'target.elf')

        def user(module, name, port=None, extra_args=()):
            path = out/(name+'.vtrace')
            result = module.generate(str(args.qemu), target, str(path), 64,
                                     unused_port() if port is None else port,
                                     list(extra_args), True, None, True, False)
            trace = new.tracefmt.read_trace(str(path))
            return result_signature(result), trace.records

        baseline = user(old, 'old-clean')
        current = user(new, 'new-clean')
        assert current == baseline and len(current[1]) > 10
        checks.append(dict(name='user-full-state-including-x87', records=len(current[1])))
        assert user(new, 'guest-g-option', extra_args=['-g', 'guest-value']) == baseline
        checks.append(dict(name='guest-g-option-preserved', records=len(current[1])))

        # The original defect must be witnessed with a QEMU owned by this test.
        for module, label in ((old, 'collision-old'), (new, 'collision-fixed')):
            port = unused_port()
            with (out/(label+'.victim.log')).open('w') as log:
                victim = subprocess.Popen([str(args.qemu), '-g', str(port),
                    '-one-insn-per-tb', str(out/'victim.elf')], stdout=log, stderr=log)
            try:
                wait_owned_listener(victim, port)
                result = user(module, label, port)
                if module is old:
                    assert result[1][0]['edi'] == '0x2468ace0'
                    assert result != baseline
                    checks.append(dict(name='old-wrong-program-reproduced',
                        records=len(result[1]), victim_pid=victim.pid))
                else:
                    assert result == baseline and victim.poll() is None
                    rsp = old.RSPClient(port=port, timeout=2)
                    try:
                        rsp.handshake()
                        layout = rsp.discover_layout()
                        raw = rsp.read_g()
                        layout.anchor_tail(len(raw))
                        pc = old.regs_to_fields(layout, raw)[0]
                        assert rsp.read_mem(pc, 5).hex() == 'bfe0ac6824'
                    finally:
                        rsp.close()
                    checks.append(dict(name='fixed-ignores-tcp-victim-unexecuted',
                                       records=len(result[1]), victim_pid=victim.pid))
            finally:
                old._terminate(victim)

        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda i: user(new, f'parallel-{i}', 1234), range(8)))
        assert all(result == baseline for result in results)
        checks.append(dict(name='eight-same-port-parallel', records=8*len(baseline[1])))

        system_results = []
        for module, label in ((old, 'system-old'), (new, 'system-new')):
            path = out/(label+'.vtrace')
            result = module.generate_system(str(args.system_qemu), str(args.bios), 'bios',
                str(path), 1000, unused_port(), ['-net', 'none'], True, None, True, False)
            system_results.append((result_signature(result), new.tracefmt.read_trace(str(path)).records))
        assert system_results[0] == system_results[1] and len(system_results[0][1]) > 10
        checks.append(dict(name='system-full-state', records=len(system_results[0][1])))

        proxy_results = []
        for module, label in ((old, 'proxy-old'), (new, 'proxy-new')):
            path = out/(label+'.vtrace')
            result = module.generate_syscall_proxy(str(args.qemu), target, str(path),
                str(out/(label+'.image.json')), 64, unused_port(), [], True, None, True,
                False, setarch=None)
            proxy_results.append((result_signature(result), new.tracefmt.read_trace(str(path)).records))
        assert proxy_results[0] == proxy_results[1]
        checks.append(dict(name='syscall-proxy-full-trace', records=len(proxy_results[0][1]),
                           initial_images_compared=False))

        disk = out/'empty.qcow2'
        subprocess.run(['/usr/bin/qemu-img', 'create', '-f', 'qcow2', str(disk), '1M'],
                       check=True, timeout=10)
        images = [module._capture_initial_phys_mem(str(args.system_qemu), str(disk),
                  unused_port(), 16, 'pentium', False) for module in (old, new)]
        assert images[0] is not None and images[0] == images[1]
        checks.append(dict(name='reset-physical-memory-full-image',
                           bytes=images[0]['meta']['bytes_captured']))
        for path, digest in pins.items():
            assert sha(path) == digest, path
        report['passed'] = True
    except BaseException as error:
        report['passed'] = False
        report['error'] = repr(error)
        raise
    finally:
        report['elapsed_seconds'] = time.monotonic() - started
        report['artifacts'] = {p.name: sha(p) for p in out.iterdir() if p.is_file()
                               and p.name not in ('closed.json',)}
        (out/'closed.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
