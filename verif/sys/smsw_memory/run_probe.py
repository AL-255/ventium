"""Bounded native QEMU/RTL cold-boot SMSW witnesses (no RTL compilation).

This initial gate self-checks data, byte footprint, GPRs and defined flags.
It is NOT a differential trace gate, page-fault test or suite acceptance.
--expect-missing explicitly requires old RTL to fail the memory cases;
the MOV controls must pass both engines. Never treat that as repaired RTL.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
EXTERNAL = Path('/home/yukidama/external/tmp').resolve(strict=True)
QEMU = REPO / 'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--model', required=True, type=Path)
    parser.add_argument('--expect-missing', action='store_true')
    args = parser.parse_args()
    root = args.root.absolute()
    assert root.parent.resolve(strict=True).is_relative_to(EXTERNAL)
    assert os.environ['TMPDIR'] == '/home/yukidama/external/tmp'
    assert shutil.disk_usage(EXTERNAL).free > 4 * 1024**3 + 128 * 1024**2
    model = args.model.resolve(strict=True)
    cpus = sorted(os.sched_getaffinity(0))[:2]
    assert len(cpus) == 2
    affinity = ','.join(map(str, cpus))
    pins = {str(path): sha(path) for path in
            (Path(__file__), HERE/'probe.S', HERE/'probe.ld', QEMU, model)}
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('VEN_', 'VENTIUM_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(AXI_RLAT='7', AXI_WLAT='7', PYTHONDONTWRITEBYTECODE='1')
    root.mkdir()

    def save(path, value):
        with path.open('x') as stream:
            json.dump(value, stream, indent=2)

    def run(name, command, seconds):
        actual = ['taskset', '-c', affinity, 'timeout', '--signal=TERM',
                  '--kill-after=2s', str(seconds)+'s', *map(str, command)]
        save(root/(name+'.command.json'), dict(argv=actual, affinity=cpus))
        with (root/(name+'.log')).open('x') as stream:
            result = subprocess.run(actual, env=env, stdout=stream,
                                    stderr=subprocess.STDOUT)
        return result.returncode

    save(root/'started.json', dict(pins=pins, affinity=cpus,
         expect_missing=args.expect_missing, invocation=os.getenv('INVOCATION_ID')))
    result = dict(passed=False, rows=[], errors=[], standard_suite=False,
                  hardware_acceptance=False, differential_gate=False,
                  gameplay_ipc=None, repaired_rtl=not args.expect_missing)
    begin = time.monotonic()
    try:
        cases = [(mode, addr, op, offset, base, 0) for mode, addr, op, offset, base in
                 itertools.product((0, 1), (0, 1), (0, 1), (0, 1, 3, 31, 4095), (0, 0x2000))]
        cases += [(mode, 0, 0, offset, base, 1) for mode, offset, base in
                  itertools.product((0, 1), (0, 4095), (0, 0x2000))]
        for case in cases:
            mode, addr, op, offset, base, control = case
            name = f'm{mode}-a{addr}-o{op}-d{offset}-b{base}-c{control}'
            defines = dict(MODE=mode, ADDR32=addr, OP32=op, OFFSET=offset,
                           BASE=base, CONTROL=control)
            obj, elf, image = [root/(name+suffix) for suffix in ('.o', '.elf', '.bin')]
            assert run(name+'-as', ['gcc', '-m32', '-ffreestanding', '-nostdlib',
                '-fno-pic', '-fno-pie', *[f'-D{k}={v}' for k,v in defines.items()],
                '-c', HERE/'probe.S', '-o', obj], 10) == 0
            assert run(name+'-ld', ['ld', '-m', 'elf_i386', '-T', HERE/'probe.ld',
                '--build-id=none', obj, '-o', elf], 10) == 0
            assert run(name+'-bin', ['objcopy', '-O', 'binary', elf, image], 10) == 0
            assert image.stat().st_size == 65536
            qemu_exit = run(name+'-qemu', [QEMU, '-display', 'none', '-monitor', 'none',
                '-serial', 'none', '-no-reboot', '-machine', 'pc', '-cpu', 'pentium',
                '-m', '32', '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04',
                '-bios', image], 5)
            rtl_exit = run(name+'-rtl', [model, '--system', '--cosim', '--cycle-func',
                '--l1-axi', '--image', image, '--out', root/(name+'.vtrace'),
                '--max-insn', '2000', '--max-cycles', '1000000', '--quiesce', '4096',
                '+ven_faultlog', '+ven_seglog'], 10)
            expected = 135 if args.expect_missing and not control else 133
            row = dict(case=defines, image_sha256=sha(image), qemu_exit=qemu_exit,
                       rtl_exit=rtl_exit, expected_rtl_exit=expected)
            result['rows'].append(row)
            assert qemu_exit == 133, ('QEMU self-check', name, qemu_exit)
            assert rtl_exit == expected, ('RTL self-check', name, rtl_exit, expected)
            log = (root/(name+'-rtl.log')).read_text()
            assert 'isa-debug-exit' in log, ('no native guest completion', name)
        result['passed'] = True
    except Exception as error:
        result['errors'].append(repr(error))
    result['pins_unchanged'] = all(sha(path) == value for path,value in pins.items())
    result['passed'] &= result['pins_unchanged']
    result['seconds'] = time.monotonic() - begin
    save(root/'closed.json', result)
    print(json.dumps({key: value for key,value in result.items() if key != 'rows'}, indent=2))
    print('cases', len(result['rows']))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
