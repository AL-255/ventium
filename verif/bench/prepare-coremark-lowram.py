#!/usr/bin/env python3
"""Produce ordinary QEMU entry images below 256 MiB, without editing them.

This only corrects Linux-user fixture placement for an identity-addressed L1
diagnostic. It does not boot an OS or qualify FPGA/standard-suite performance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools'))
from run_coremark_matrix import parse_crc_output, STANDARD_CRCS

LIMIT = 0x10000000
ELF_SHA = '8d8b84ad407b1ec35344415084fa4b77afa9dfd2b6369e1677345816ee2c7dbe'
QEMU_SHA = 'e873771c34647c1cbcb30d2ad1d3efa018e2530a0c90c598ccb0179425df064e'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def audit_image(image):
    """Reject MMIO/high-memory, missing entry/stack, and malformed ranges."""
    ranges = []
    for region in image['regions']:
        start = int(region['vaddr'], 16)
        if 'hex' in region:
            length = len(bytes.fromhex(region['hex']))
        else:
            assert region['zero'] is True
            length = region['len']
        assert isinstance(length, int) and 0 < length <= LIMIT
        assert 0x100000 <= start < start + length <= LIMIT
        ranges.append((start, start + length))
    for name in ('eip', 'esp'):
        address = int(image['regs'][name], 16)
        assert any(start <= address < end for start, end in ranges), name
    assert int(image['regs']['esp'], 16) - 65536 >= 0x100000
    assert image['meta']['cpu'] == 'pentium' and image['meta']['seed'] == 1234
    return dict(esp=image['regs']['esp'], entry=image['regs']['eip'],
                ranges=ranges, highest_byte=max(end for _, end in ranges)-1)


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    refs = REPO / 'ventium-refs/07-p5-emulation-harness'
    qemu = refs / 'build/qemu/build/qemu-i386'
    elf = refs / 'benchmarks/bin/coremark'
    generator = REPO / 'verif/qemu-trace/gen_trace.py'
    assert sha(qemu) == QEMU_SHA and sha(elf) == ELF_SHA
    sources = [qemu, elf, generator, Path(__file__),
               REPO / 'verif/diff/tracefmt.py',
               REPO / 'tools/run_coremark_matrix.py']
    pins = {str(p.resolve()): sha(p) for p in sources}
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('QEMU_', 'VEN_', 'TB_', 'AXI_'))}
    env.update(TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1', LC_ALL='C')
    save(out / 'started.json', dict(pins=pins, reserved_va=LIMIT,
         score_eligible=False, standard_suite=False, gameplay_ipc=None))
    results = []
    for seed, seeds, final in (('performance', ['0', '0', '0x66'], 'fcaf'),
                               ('validation', ['0x3415', '0x3415', '0x66'], 'c64e')):
        row = out / seed
        row.mkdir()
        guest_args = seeds + ['10', '7']
        qemu_args = ['-R', hex(LIMIT)]
        command = [str(qemu), '-cpu', 'pentium', '-seed', '1234',
                   *qemu_args, str(elf), *guest_args]
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        image = row / 'entry.image.json'
        generate = [sys.executable, str(generator), '--qemu', str(qemu),
            '--elf', str(elf), '--syscall-proxy', '--image-out', str(image),
            '--out', str(row / 'entry.vtrace'), '--max-insn', '0',
            '--port', str(port), '--qemu-arg=-R', '--qemu-arg=' + hex(LIMIT),
            '--args', *guest_args]
        save(row / 'command.json', dict(reference=command, generator=generate))
        with (row / 'qemu.stdout').open('x') as stdout, (row / 'qemu.stderr').open('x') as stderr:
            subprocess.run(command, stdout=stdout, stderr=stderr, env=env,
                           check=True, timeout=60)
        reference = (row / 'qemu.stdout').read_text()
        expected = dict(STANDARD_CRCS[seed], crcfinal=final)
        assert parse_crc_output(reference) == expected
        assert re.findall(r'^ERROR!.*$', reference, re.M) == [
            'ERROR! Must execute for at least 10 secs for a valid result!']
        with (row / 'generate.log').open('x') as log:
            subprocess.run(generate, stdout=log, stderr=subprocess.STDOUT,
                           env=env, check=True, timeout=60)
        placement = audit_image(json.loads(image.read_text()))
        assert len((row / 'entry.vtrace').read_text().splitlines()) == 1
        results.append(dict(seed=seed, iterations=10, image=str(image),
            image_sha256=sha(image), crcfinal=final, expected_crc=expected,
            placement=placement, qemu_native_exit=0, generator_native_exit=0))
    assert all(sha(p) == digest for p, digest in pins.items())
    save(out / 'closed.json', dict(passed=True, pins=pins, workloads=results,
        unchanged_benchmark=True, image_edits=False, reserved_va=LIMIT,
        score_eligible=False, standard_suite=False, gameplay_ipc=None))
    print(json.dumps([dict(seed=r['seed'], esp=r['placement']['esp'],
                          highest_byte=hex(r['placement']['highest_byte'])) for r in results]))


if __name__ == '__main__':
    main()
