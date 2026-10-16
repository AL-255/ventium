"""Diagnose the resync proposal with an explicitly bounded transport TB variant.

The original extended run remains failed. This separate run keeps every data,
parity, IRQ, abort and completion assertion, but budgets two 8192-cycle inhibit
intervals (reset resync plus SEND) instead of the old 15000-cycle allowance.
No controller/transport RTL or active FPGA inputs are modified.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
BASE = ROOT/'ps2-loss-aux-extended-r2'
TB_SHA = '82d2bae54c414f3dcf4e52e35730d75dc3c27ffa50ffc0cffeb820e9d6bf6348'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def bounded_tb(source):
    if hashlib.sha256(source.encode()).hexdigest() != TB_SHA:
        raise ValueError('original transport TB drift')
    before = 'while (!rx_valid && n < 15000+CELL*12) begin'
    after = 'while (!rx_valid && n < 2*8192+CELL*12+256) begin'
    anchor = '            repeat (32) begin\n'
    if source.count(before) != 1 or source.count(anchor) != 1:
        raise ValueError('transport TB anchor drift')
    return source.replace(before, after).replace(anchor,
        '            $display("PS2-RECEIVE-LATENCY hz=%0d byte=%02x clocks=%0d limit=%0d",'
        'HZ,expected,n,2*8192+CELL*12+256);\n'+anchor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(); out = args.out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    assert out.parent.resolve(strict=True) == ROOT and not out.exists()
    assert sorted(os.sched_getaffinity(0)) == [12, 13]
    assert shutil.disk_usage(ROOT).free > 4*1024**3
    group = Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0 < int((group/'memory.max').read_text()) <= 512*1024**2
    assert (group/'memory.swap.max').read_text().strip() == '0'
    assert 0 < int((group/'pids.max').read_text()) <= 32
    old = json.loads((BASE/'started.json').read_text())
    failed = json.loads((BASE/'closed.json').read_text())
    assert old['invocation'] == 'b20d3d4239844ae891581fa90cda6472'
    assert not failed['passed'] and failed['errors'] == [
        'candidate-transport-autoack0', 'candidate-transport-autoack1']
    files = {n: BASE/'source'/n for n in (
        'parent.v', 'candidate.v', 'simple_fifo.v', 'ven_ps2_device.sv', 'tb_ps2_device.sv')}
    for name, path in files.items():
        matches = [h for p, h in old['pins'].items() if Path(p).resolve(strict=True) == path]
        assert len(matches) == 1 and sha(path) == matches[0], name
    out.mkdir(); source = out/'source'; source.mkdir()
    pins = {str(p): sha(p) for p in [*files.values(), Path(__file__).resolve(),
                                    BASE/'started.json', BASE/'closed.json']}
    for name, path in files.items():
        shutil.copyfile(path, source/name)
        assert sha(source/name) == pins[str(path)]
        pins[str(source/name)] = sha(source/name)
    generated = source/'tb_ps2_device_bounded.sv'
    with generated.open('x') as stream:
        stream.write(bounded_tb((source/'tb_ps2_device.sv').read_text()))
    pins[str(generated)] = sha(generated)
    native_tools = {n: str(Path(shutil.which(n)).resolve(strict=True)) for n in ('iverilog', 'vvp')}
    pins.update({p: sha(p) for p in native_tools.values()})

    def save(name, value):
        with (out/name).open('x') as stream: json.dump(value, stream, indent=2)

    cases = [(label, ack) for label in ('parent', 'candidate') for ack in (0, 1)]
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=[12, 13], cases=cases, original_run_passed=False,
        timeout_formula='2*8192 + CELL*12 + 256', original_formula='15000 + CELL*12',
        full_pc=False, physical_fpga=False))
    start = time.monotonic(); builds = []; rows = []; errors = []

    def execute(case):
        label, ack = case; name = f'{label}-autoack{ack}'
        assert time.monotonic()-start < 280 and shutil.disk_usage(ROOT).free > 4*1024**3
        command = [native_tools['vvp'], str(out/(name+'.vvp'))]
        path = out/(name+'.log')
        with path.open('x') as stream:
            child = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT)
            affinity = sorted(os.sched_getaffinity(child.pid)); assert affinity == [12, 13]
            try: code = child.wait(timeout=115)
            except BaseException:
                child.kill(); child.wait(); raise
        text = path.read_text()
        counts = [tuple(map(int, row)) for row in re.findall(
            r'PS2-DEVICE-OK hz=(\d+) checks=(\d+) completed=(\d+) aborted=(\d+)', text)]
        latencies = [(int(hz), int(byte, 16), int(clocks), int(limit)) for hz, byte, clocks, limit
                     in re.findall(r'PS2-RECEIVE-LATENCY hz=(\d+) byte=([0-9a-f]+) clocks=(\d+) limit=(\d+)', text)]
        good = (code == 0 and sorted(counts) == [(3125000, 49, 26, 2), (40000000, 49, 26, 2)]
                and 'PS2-DEVICE-ALL-OK profiles=2' in text and len(latencies) == 36
                and all(clocks < limit for _, _, clocks, limit in latencies))
        row = dict(label=name, native_exit=code, passed=good, command=command,
                   affinity=affinity, counts=counts, latencies=latencies,
                   log=str(path), log_sha256=sha(path))
        print(json.dumps({k: row[k] for k in ('label', 'native_exit', 'passed', 'counts')}), flush=True)
        return row

    try:
        for label, ack in cases:
            name = f'{label}-autoack{ack}'
            command = [native_tools['iverilog'], '-g2012', '-Wall', '-s', 'tb_ps2_device', '-DVEN_KBC_FAST',
                       *(['-DVEN_KBD_AUTOACK'] if ack else []), '-o', str(out/(name+'.vvp')),
                       *[str(source/n) for n in (label+'.v', 'simple_fifo.v', 'ven_ps2_device.sv')], str(generated)]
            with (out/(name+'-compile.log')).open('x') as stream:
                result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=30)
            builds.append(dict(command=command, native_exit=result.returncode))
            assert result.returncode == 0, name+' compile failed'
        with ThreadPoolExecutor(max_workers=2) as pool:
            for row in pool.map(execute, cases):
                rows.append(row)
                if not row['passed']: errors.append(row['label'])
    except Exception as exc: errors.append(repr(exc))
    stable = all(sha(p) == h for p, h in pins.items())
    events = {k: int(v) for k, v in (s.split() for s in (group/'memory.events').read_text().splitlines())}
    result = dict(passed=not errors and stable and len(rows) == 4 and
                  not any(events[k] for k in ('oom', 'oom_kill', 'oom_group_kill')),
        rows=rows, builds=builds, errors=errors, pins_unchanged=stable, memory_events=events,
        memory_peak=int((group/'memory.peak').read_text()), seconds=time.monotonic()-start,
        original_run_passed=False, full_pc=False, physical_fpga=False, standard_suite=False, gameplay_ipc=None)
    save('closed.json', result)
    print(json.dumps({k: v for k, v in result.items() if k not in ('rows', 'builds')}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
