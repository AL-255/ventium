#!/usr/bin/env python3
"""Isolated PS/2 transport microgate. No Vivado, guest or board access.

Run in a <=512 MiB, no-swap cgroup on one CPU; see PS2_DEVICE.md.
Pass the frozen platform's rtl/ directory, not an unspecified live checkout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--platform-root', type=Path, required=True)
    args = ap.parse_args()
    assert __debug__
    scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
    assert scratch == Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert scratch.is_mount() or scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 2*1024**3
    assert len(os.sched_getaffinity(0)) == 1
    cg = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().split('::', 1)[1].strip().lstrip('/')
    assert 0 < int((cg/'memory.max').read_text()) <= 512*1024**2
    assert (cg/'memory.swap.max').read_text().strip() == '0'
    assert 0 < int((cg/'pids.max').read_text()) <= 32
    assert os.environ.get('INVOCATION_ID'), 'use a retained bounded service'
    platform = args.platform_root.resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix='ventium-ps2-device-gate.', dir=scratch))
    print(root, flush=True)
    (root/'source').mkdir()
    inputs = [REPO/'fpga/ven_ps2_device.sv', REPO/'fpga/tb_ps2_device.sv',
              platform/'soc/ps2.v', platform/'common/simple_fifo.v', Path(__file__)]
    originals = {str(p): sha(p) for p in inputs}
    compiled = []
    for p in inputs[:4]:
        copy = root/'source'/p.name
        shutil.copyfile(p, copy)
        assert sha(copy) == originals[str(p)]
        compiled.append(copy)
    pins = {**originals, **{str(p): sha(p) for p in compiled}}
    tools = {name: str(Path(shutil.which(name)).resolve(strict=True)) for name in ('iverilog', 'vvp')}
    pins.update({p: sha(p) for p in tools.values()})

    def save(name, obj):
        with (root/name).open('x') as f:
            json.dump(obj, f, indent=2)
            f.write('\n')

    def events():
        return dict(line.split() for line in (cg/'memory.events').read_text().splitlines())

    rows = []

    def command(label, argv, expected=0):
        begin = time.monotonic()
        with (root/(label+'.log')).open('xb') as log:
            proc = subprocess.run(argv, cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        rows.append(dict(label=label, argv=argv, exit=proc.returncode, seconds=time.monotonic()-begin))
        assert proc.returncode == expected, (label, proc.returncode)
        return (root/(label+'.log')).read_text()

    def build(label, source, extra=()):
        image = root/(label+'.vvp')
        command(label+'-compile', [tools['iverilog'], '-g2012', '-Wall',
            '-s', 'tb_ps2_device', '-o', str(image), *extra,
            str(source), *map(str, compiled[1:])])
        return image

    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), memory_before=events(),
        platform=str(platform), hardware_acceptance=False, gameplay_ipc=None))
    failure = None
    results = []
    try:
        text = command('native', [tools['vvp'], str(build('native', compiled[0]))])
        results = [dict(hz=int(h), checks=int(c), completed=int(d), aborted=int(a))
            for h,c,d,a in re.findall(r'PS2-DEVICE-OK hz=(\d+) checks=(\d+) completed=(\d+) aborted=(\d+)', text)]
        assert {r['hz'] for r in results} == {3125000, 40000000} and len(results) == 2
        assert all((r['checks'], r['completed'], r['aborted']) == (49, 26, 2) for r in results)
        assert 'PS2-DEVICE-ALL-OK profiles=2' in text
        # A real DUT mutation must be caught by the independent serial-bit
        # oracle, not merely by a build failure or arbitrary nonzero exit.
        source = compiled[0].read_text()
        assert source.count('~^tx_data') == 1
        mutant = root/'even-parity.sv'
        mutant.write_text(source.replace('~^tx_data', '^tx_data'))
        pins[str(mutant)] = sha(mutant)
        rejected = command('even-parity', [tools['vvp'], str(build('even-parity', mutant))], expected=1)
        assert 'TX bit/parity mismatch' in rejected
        for hz in (-1, 0, 999999, 100000001):
            label = 'invalid-clock-'+str(hz)
            image = root/(label+'.vvp')
            command(label+'-compile', [tools['iverilog'], '-g2012', '-s', 'ven_ps2_device',
                '-Pven_ps2_device.CLK_HZ='+str(hz), '-o', str(image), str(compiled[0])])
            rejected = command(label, [tools['vvp'], str(image)], expected=1)
            assert 'supports 1..100 MHz synchronous hosts' in rejected
    except Exception as error:
        failure = repr(error)
    stable = all(sha(Path(p)) == h for p,h in pins.items())
    after = events()
    result = dict(passed=failure is None and stable and after['oom']=='0' and after['oom_kill']=='0',
        error=failure, results=results, commands=rows, pins=pins, pins_unchanged=stable,
        memory_after=after, memory_peak=int((cg/'memory.peak').read_text()),
        integrated_candidate=False, physical_board=False, standard_suite=False, gameplay_ipc=None)
    save('closed.json', result)
    print(json.dumps(dict(passed=result['passed'], error=failure, evidence=str(root), results=results)), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
