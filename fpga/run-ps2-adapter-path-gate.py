#!/usr/bin/env python3
"""Actual mouse adapter + AXI management + mailbox + wires + frozen 8042.

The socket/input endpoint is real; ordered MMIO callbacks are simulated AXI
transactions. No /dev/mem, ARM execution, processor, Windows or board is tested.
No active FPGA export is modified. Keep this separate from FPGA acceptance.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import shutil
import socket
import subprocess
import sys
import time


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--overlay', type=Path, required=True)
    parser.add_argument('--platform-root', type=Path, required=True)
    parser.add_argument('--fpga-defines', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert scratch.stat().st_dev != repo.stat().st_dev
    assert out.parent == scratch and not list(out.iterdir())
    assert shutil.disk_usage(out).free > 4*1024**3
    affinity = sorted(os.sched_getaffinity(0))
    assert len(affinity) == 1 and os.environ.get('INVOCATION_ID')
    cgroup = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().split('::')[1].strip().lstrip('/')
    assert 0 < int((cgroup/'memory.max').read_text()) <= 512*1024**2
    assert (cgroup/'memory.swap.max').read_text().strip() == '0'
    assert 0 < int((cgroup/'pids.max').read_text()) <= 32
    source = out/'source'; source.mkdir()
    paths = [repo/'fpga'/name for name in (
        'tb_ps2_adapter_path.sv', 'tb_ps2_mailbox_mgmt.sv',
        'prepare_ps2_mouse_mailbox.py', 'run-ps2-mouse-policy-gate.py',
        'board-tools/ven_ps2_mouse.py', 'board-tools/ven_ps2_mailbox_host.py',
        'board-tools/ven_ps2_service.py', 'board-tools/ven_ps2_mmio.py')]
    paths += [args.overlay/'src'/name for name in (
        'ven_mgmt_axil.v', 'ven_ps2_mailbox.sv', 'ven_ps2_device.sv')]
    paths += [args.platform_root/'soc/ps2.v', args.platform_root/'common/simple_fifo.v',
              args.fpga_defines, args.overlay/'prepared.json', Path(__file__).resolve()]
    paths = [p.resolve(strict=True) for p in paths]
    assert len({p.name for p in paths}) == len(paths)
    pins = {str(p): sha(p) for p in paths}
    for path in paths:
        shutil.copyfile(path, source/path.name)
        assert sha(source/path.name) == pins[str(path)]
        pins[str(source/path.name)] = pins[str(path)]
    overlay = json.loads((source/'prepared.json').read_text())
    assert overlay['kind'] == 'PS2_MOUSE_CSR_SOURCE_OVERLAY'
    for name, digest in overlay['files'].items():
        assert sha(args.overlay/name) == digest, name
        pins[str((args.overlay/name).resolve())] = digest
    for name in ('ven_ps2_device.sv', 'ven_ps2_mailbox.sv'):
        assert sha(repo/'fpga'/name) == sha(source/name), 'overlay/source drift'
        pins[str(repo/'fpga'/name)] = sha(source/name)
    spec = importlib.util.spec_from_file_location('profile', source/'run-ps2-mouse-policy-gate.py')
    profile = importlib.util.module_from_spec(spec); spec.loader.exec_module(profile)
    definitions = profile.kbc_defines((source/'ps2.v').read_text(), (source/args.fpga_defines.name).read_text())
    template = (source/'tb_ps2_adapter_path.sv').read_text()
    original = (source/'tb_ps2_mailbox_mgmt.sv').read_text()
    begin, end = '    ven_mgmt_axil mgmt (', '    ven_ps2_mailbox mailbox ('
    assert original.count(begin) == original.count(end) == 1
    instance = original[original.index(begin):original.index(end)]
    anchor = '    // @ACTUAL_MANAGEMENT_INSTANCE@'
    assert template.count(anchor) == 1
    generated = source/'tb_ps2_adapter_path_generated.sv'
    generated.write_text(template.replace(anchor, instance))
    pins[str(generated)] = sha(generated)
    tools = {name: str(Path(shutil.which(name)).resolve(strict=True)) for name in ('iverilog', 'vvp')}
    pins.update({p: sha(p) for p in tools.values()})
    sys.path.insert(0, str(source))
    from ven_ps2_mailbox_host import Adapter
    from ven_ps2_service import Endpoint
    assert Path(sys.modules[Adapter.__module__].__file__).resolve() == source/'ven_ps2_mailbox_host.py'
    assert Path(sys.modules[Endpoint.__module__].__file__).resolve() == source/'ven_ps2_service.py'
    os.chdir(source)  # Short relative Unix socket name, below sockaddr_un limit.
    rows = []

    def save(name, value):
        with (out/name).open('x') as stream:
            json.dump(value, stream, indent=2); stream.write('\n')

    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=affinity, definitions=definitions, physical_board=False,
        scope='socket input endpoint + adapter + AXI BFM + real management/mailbox/wire/8042'))

    def run(hz, *, bad_parity=False):
        label = ('bad-parity-' if bad_parity else 'path-') + str(hz)
        image = out/(label+'.vvp')
        device = source/'ven_ps2_device.sv'
        if bad_parity:
            text = device.read_text(); old = "tx_frame <= {1'b1, ~^tx_data, tx_data, 1'b0};"
            assert text.count(old) == 1
            device = source/'ven_ps2_device_bad_parity.sv'
            device.write_text(text.replace(old, "tx_frame <= {1'b1, ^tx_data, tx_data, 1'b0};"))
            pins[str(device)] = sha(device)
        build = [tools['iverilog'], '-g2012', '-Wall', '-s', 'tb_ps2_adapter_path',
            '-Ptb_ps2_adapter_path.HZ='+str(hz), '-o', str(image),
            *['-D'+d for d in definitions], str(device), str(generated),
            *[str(source/n) for n in ('ven_ps2_mailbox.sv', 'ven_mgmt_axil.v', 'ps2.v', 'simple_fifo.v')]]
        with (out/(label+'-build.log')).open('xb') as log:
            subprocess.run(build, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=30)
        start = time.monotonic()
        proc = subprocess.Popen([tools['vvp'], str(image)], cwd=out,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
        selector = selectors.DefaultSelector(); selector.register(proc.stdout, selectors.EVENT_READ)
        native = dict(pid=proc.pid, affinity=sorted(os.sched_getaffinity(proc.pid)),
            exe=str((Path('/proc')/str(proc.pid)/'exe').resolve(strict=True)))
        assert native['affinity'] == affinity and native['exe'] == tools['vvp']
        buffer = b''; requests = cycles = delivered = commands = 0
        actions = []; packets = []; endpoint = None; error = None; status = None
        with (out/(label+'.log')).open('xb') as log, (out/(label+'-transactions.jsonl')).open('x') as txlog:
            def line():
                nonlocal buffer
                deadline = min(start+230, time.monotonic()+20)
                while b'\n' not in buffer:
                    left = deadline-time.monotonic()
                    if left <= 0 or not selector.select(left): raise TimeoutError('native adapter-path response')
                    data = os.read(proc.stdout.fileno(), 65536)
                    if not data: raise RuntimeError('native EOF: '+repr(buffer))
                    log.write(data); log.flush(); buffer += data
                result, buffer = buffer.split(b'\n', 1)
                return result.decode()

            def command(op, address=0, value=0):
                nonlocal requests, cycles
                requests += 1
                proc.stdin.write(f'{op} {address:x} {value:x}\n'.encode()); proc.stdin.flush()
                response = line()
                txlog.write(json.dumps(dict(op=op, address=address, value=value, response=response))+'\n')
                fields = response.split()
                if op == 0: return fields
                assert len(fields) == 4 and fields[:2] == ['RESULT', str(requests)], response
                cycles = int(fields[3])
                return int(fields[2], 16)

            def read(index): return command(1, 0x400+16*index)
            def write(index, value):
                command(2, 0x400+16*index, value)
                read(1)  # Same-device readback, like the ordered native backend.
            def poll():
                action = host.poll(cycles*1_000_000_000//hz)
                actions.append(action)
                assert action != 'needs_reset'
                return action
            def pump(expected):
                nonlocal delivered
                result = []
                first = cycles
                for _ in range(1200):
                    poll(); command(5, 0, hz//10000)  # 100 us of actual serial time.
                    status_word = command(3, 4)
                    if status_word & 1:
                        assert status_word & 0xA3 == 0x21, hex(status_word)
                        assert command(6) == 1, 'real IRQ12 absent or IRQ1 incorrectly asserted'
                        byte = command(3, 0); result.append(byte); delivered += 1
                        assert result == expected[:len(result)], (result, expected)
                        assert command(6) == 0, 'IRQ12 not consumed by port 60h'
                    if len(result) == len(expected) and host.flight is None and host.pending is None:
                        break
                    assert cycles-first < hz//10, '100 ms virtual delivery deadline'
                else: raise AssertionError('adapter delivery loop exhausted')
                assert result == expected, (result, expected)
                packets.append(result)
            def guest(value, expected):
                nonlocal commands
                assert command(3, 4) & 3 == 0, 'guest buffers not drained'
                command(4, 4, 0xD4); command(4, 0, value)
                pump(expected); commands += 1
            def sensor(**payload):
                with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as client:
                    client.connect(str(endpoint.path))
                    client.send(json.dumps(dict(op='input', **payload)).encode())
                    client.setblocking(False)
                    for _ in range(20):
                        endpoint.step(0)
                        try: reply = client.recv(512); break
                        except BlockingIOError: pass
                    else: raise AssertionError('local input endpoint failed to answer')
                assert json.loads(reply) == dict(ok=True, queued=True, delivery_confirmed=False)
            try:
                assert line() == f'READY ADAPTER-PATH {hz}'
                host = Adapter(read, write)
                assert poll() == 'reset'
                command(2, 0x20, 2)  # Ordinary launcher control, not adapter reset access.
                pump([0xAA, 0])
                endpoint = Endpoint('adapter-path-input.sock', host)
                guest(0xFF, [0xFA, 0xAA, 0])
                guest(0xF2, [0xFA, 0])
                guest(0xF3, [0xFA]); guest(200, [0xFA])
                guest(0xE8, [0xFA]); guest(3, [0xFA])
                guest(0xE9, [0xFA, 0, 3, 200])
                guest(0xF4, [0xFA])
                sensor(dx=20, dy=-12, buttons=1); pump([0x29, 20, 244])
                guest(0xFE, [0x29, 20, 244])
                sensor(buttons=0); pump([8, 0, 0])
                guest(0xF0, [0xFA])
                sensor(dx=-128, dy=255, buttons=6)
                guest(0xEB, [0xFA, 0x1E, 128, 255])
                guest(0xE9, [0xFA, 0x63, 3, 200])
                guest(0xEE, [0xFA]); guest(0xA5, [0xA5]); guest(0xEC, [0xFA])
                guest(0xF5, [0xFA]); guest(0xF6, [0xFA])
                guest(0xE9, [0xFA, 3, 2, 100])
                guest(0xFF, [0xFA, 0xAA, 0])
                # Reset via the same management register invalidates the adapter,
                # mailbox, transport and controller together, then requires rearm.
                generation = host.generation
                command(2, 0x20, 1); assert poll() == 'reset'
                assert host.generation == generation+1
                command(2, 0x20, 2); pump([0xAA, 0])
                guest(0xF2, [0xFA, 0])
                assert host.pending is None and host.flight is None
                finish = command(0)
                assert finish == ['DONE', str(requests), str(delivered), str(commands), '0', str(cycles)]
                proc.stdin.close(); proc.stdin = None
                tail = proc.communicate(timeout=5)[0]; log.write(tail)
                status = proc.wait(timeout=5); assert status == 0
            except Exception as failure:
                error = repr(failure)
            finally:
                if endpoint is not None: endpoint.close()
                selector.close()
                if proc.poll() is None:
                    try: proc.wait(timeout=1)
                    except subprocess.TimeoutExpired: proc.kill()
                status = proc.wait(timeout=5)
                if not proc.stdout.closed:
                    tail = proc.stdout.read(); log.write(tail)
                    proc.stdout.close()
                if proc.stdin is not None: proc.stdin.close()
                log.flush()
        row = dict(label=label, hz=hz, build=build, native=native, native_exit=status,
            error=error, seconds=time.monotonic()-start, requests=requests,
            commands=commands, delivered=delivered, actions=actions, packets=packets,
            child_reaped=True, cycles=cycles)
        rows.append(row)
        if bad_parity:
            assert status == 1 and 'ADAPTER-PATH wire data/parity mismatch' in (out/(label+'.log')).read_text(), row
            row['mutation_rejected_by_native_assertion'] = True
        else:
            assert error is None and status == 0, row
            assert commands == 20 and delivered == 50, row

    error = None
    try:
        for hz in (3125000, 40000000): run(hz)
        run(3125000, bad_parity=True)
    except Exception as failure:
        error = repr(failure)
    stable = all(sha(p) == h for p, h in pins.items())
    events = dict(x.split() for x in (cgroup/'memory.events').read_text().splitlines())
    passed = error is None and stable and events['oom'] == events['oom_kill'] == '0'
    save('closed.json', dict(passed=passed, error=error, rows=rows, pins=pins,
        pins_unchanged=stable, memory_peak=int((cgroup/'memory.peak').read_text()),
        memory_events=events, physical_board=False, native_mmio=False,
        processor=False, windows=False, standard_suite=False, gameplay_ipc=None))
    print(json.dumps(dict(passed=passed, error=error, out=str(out))), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
