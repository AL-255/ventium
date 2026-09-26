#!/usr/bin/env python3
"""Actual-core A20 DD/DF regression; existing binary only, no implicit rebuild."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = [0x1111, 0x2222, 0x2222, 0x1111, 0x1111, 0x3333,
            0x2222, 0x2222, 0x3333, 0x3333, 0x4444]


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tb', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    subprocess.run([ROOT / 'tools/build_scope.sh', '--is-active'], check=True,
                   close_fds=False)
    tb = args.tb.resolve(strict=True)
    out = args.out.resolve()
    out.mkdir()  # never overwrite an earlier result, including failures
    src = ROOT / 'verif/sys/tests/mabench/a20cmdtest.S'
    ld = ROOT / 'verif/sys/tests/mabench/mabench.ld'
    qemu = ROOT / 'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    frozen = {str(p): sha(p) for p in (tb, src, ld, qemu, Path(__file__).resolve())}
    receipt = dict(scope='DD/DF warmed physical data/executable aliases and completed D1-to-DF handoff; not full boot',
                   expected=EXPECTED, inputs=frozen, stages=[], pass_=False,
                   gameplay_ipc=0.297507, gameplay='wave7 1.100B–1.101B; candidate unmeasured',
                   error=None)

    def save():
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')

    def run(name, argv, allowed=(0,)):
        start = time.monotonic()
        with (out / (name + '.log')).open('x') as log:
            result = subprocess.run(list(map(str, argv)), cwd=ROOT, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=120,
                                    close_fds=False)
        stage = dict(name=name, argv=list(map(str, argv)), exit=result.returncode,
                     seconds=time.monotonic() - start)
        receipt['stages'].append(stage)
        save()
        if result.returncode not in allowed:
            raise ValueError(f'{name} process failed: {result.returncode}')
        return stage

    def witness(name, argv, allowed):
        stage = run(name, argv, allowed)
        text = (out / (name + '.log')).read_text(errors='replace')
        found = re.findall(r'@((?:[0-9a-f]{4}:){11})', text)
        if len(found) != 1:
            raise ValueError(f'{name}: expected exactly one complete witness')
        values = [int(v, 16) for v in found[0].split(':')[:-1]]
        stage.update(values=values, correct=values == EXPECTED)
        save()
        return stage['correct']

    try:
        image = out / 'a20cmd.bin'
        run('assemble', ['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic',
                         '-fno-pie', '-c', src, '-o', out / 'a20cmd.o'])
        run('link', ['ld', '-m', 'elf_i386', '-T', ld, out / 'a20cmd.o', '-o', out / 'a20cmd.elf'])
        run('binary', ['objcopy', '-O', 'binary', out / 'a20cmd.elf', image])
        with image.open('r+b') as stream:
            stream.truncate(65536)
        receipt['image_sha256'] = sha(image)
        assert witness('qemu', [qemu, '-cpu', 'pentium', '-machine', 'pc', '-m', '32',
            '-display', 'none', '-serial', 'stdio', '-monitor', 'none', '-no-reboot',
            '-bios', image, '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], (133,)), 'QEMU witness failed'
        passed = []
        for name, extra in [('func', []), ('cycle', ['--cycle'])]:
            passed.append(witness(name, [tb, '--system', '--cosim', '--l1-axi',
                '--image', image, '--out', out / (name + '.vtrace'), '--max-insn', '10000',
                '--quiesce', '100000', '--max-cycles', '1000000', *extra], (0, 133)))
        receipt['pass_'] = all(passed)
    except Exception as exc:
        receipt['error'] = repr(exc)
    finally:
        receipt['input_drift'] = [p for p, digest in frozen.items() if sha(Path(p)) != digest]
        receipt['pass_'] = receipt['pass_'] and not receipt['input_drift'] and receipt['error'] is None
        save()
    print('A20CMD-' + ('PASS' if receipt['pass_'] else 'FAIL'), out, flush=True)
    if receipt['error']:
        print(receipt['error'], flush=True)
    raise SystemExit(0 if receipt['pass_'] else 1)


if __name__ == '__main__':
    main()
