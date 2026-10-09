#!/usr/bin/env python3
"""Reference-check unmodified CoreMark seeds at a specified iteration count.

Produces QEMU entry images, not checkpoints inside the benchmark. No result is
score-eligible until the RTL run independently satisfies all duration/CRC gates.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / 'verif/bench/prepare-coremark-lowram.py'
spec = importlib.util.spec_from_file_location('lowram_fixture', SOURCE)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def reference_crcs(text, seed, iterations):
    actual = fixture.parse_crc_output(text)
    standard = fixture.STANDARD_CRCS[seed]
    assert set(actual) == set(standard) | {'crcfinal'}, 'missing/unexpected CRC'
    assert all(actual[key] == value for key, value in standard.items()), 'data CRC mismatch'
    assert re.findall(r'^Iterations\s*:\s*(\d+)\s*$', text, re.M) == [str(iterations)]
    assert re.findall(r'^CoreMark Size\s*:\s*(\d+)\s*$', text, re.M) == ['666']
    errors = re.findall(r'^ERROR!.*$', text, re.M)
    assert errors in ([], ['ERROR! Must execute for at least 10 secs for a valid result!'])
    # The reference's duration-only error also prints its generic summary.
    # This fixture receipt is NOT a score; the RTL acceptance keeps rejecting
    # either message and still requires its own >=10-second validated run.
    summary = re.findall(r'^(Errors detected|Correct operation validated\.)$', text, re.M)
    assert summary == (['Errors detected'] if errors else ['Correct operation validated.'])
    return actual


def region_pins(image):
    result = []
    for region in image['regions']:
        data = bytes.fromhex(region['hex']) if 'hex' in region else bytes(region['len'])
        result.append(dict(vaddr=region['vaddr'], length=len(data),
                           sha256=hashlib.sha256(data).hexdigest()))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--iterations', type=int, required=True)
    args = parser.parse_args()
    assert 0 < args.iterations <= 100000
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    refs = REPO / 'ventium-refs/07-p5-emulation-harness'
    qemu = refs / 'build/qemu/build/qemu-i386'
    elf = refs / 'benchmarks/bin/coremark'
    generator = REPO / 'verif/qemu-trace/gen_trace.py'
    assert fixture.sha(qemu) == fixture.QEMU_SHA and fixture.sha(elf) == fixture.ELF_SHA
    sources = [qemu, elf, generator, SOURCE, Path(__file__),
               REPO / 'verif/diff/tracefmt.py', REPO / 'tools/run_coremark_matrix.py']
    pins = {str(path.resolve()): fixture.sha(path) for path in sources}
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('QEMU_', 'VEN_', 'TB_', 'AXI_'))}
    env.update(TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1', LC_ALL='C')
    fixture.save(out / 'started.json', dict(pins=pins, iterations=args.iterations,
                 reserved_va=fixture.LIMIT, score_eligible=False, standard_suite=False))
    results = []
    for seed, values in [('performance', ['0', '0', '0x66']),
                         ('validation', ['0x3415', '0x3415', '0x66'])]:
        row = out / seed
        row.mkdir()
        guest_args = values + [str(args.iterations), '7']
        command = [str(qemu), '-cpu', 'pentium', '-seed', '1234',
                   '-R', hex(fixture.LIMIT), str(elf), *guest_args]
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        image = row / 'entry.image.json'
        generate = [sys.executable, str(generator), '--qemu', str(qemu),
            '--elf', str(elf), '--syscall-proxy', '--image-out', str(image),
            '--out', str(row / 'entry.vtrace'), '--max-insn', '0',
            '--port', str(port), '--qemu-arg=-R', '--qemu-arg=' + hex(fixture.LIMIT),
            '--args', *guest_args]
        fixture.save(row / 'command.json', dict(reference=command, generator=generate))
        with (row / 'qemu.stdout').open('x') as stdout, (row / 'qemu.stderr').open('x') as stderr:
            reference = subprocess.run(command, stdout=stdout, stderr=stderr, env=env,
                                       check=True, timeout=60)
        expected = reference_crcs((row / 'qemu.stdout').read_text(), seed, args.iterations)
        with (row / 'generate.log').open('x') as log:
            generated = subprocess.run(generate, stdout=log, stderr=subprocess.STDOUT,
                                       env=env, check=True, timeout=60)
        contents = json.loads(image.read_text())
        placement = fixture.audit_image(contents)
        assert len((row / 'entry.vtrace').read_text().splitlines()) == 1
        results.append(dict(seed=seed, iterations=args.iterations, image=str(image),
            image_sha256=fixture.sha(image), crcfinal=expected['crcfinal'], expected_crc=expected,
            placement=placement, region_pins=region_pins(contents),
            qemu_native_exit=reference.returncode, generator_native_exit=generated.returncode,
            artifacts={str(p): fixture.sha(p) for p in row.iterdir()}))
    assert all(fixture.sha(path) == digest for path, digest in pins.items())
    fixture.save(out / 'closed.json', dict(passed=True, pins=pins, workloads=results,
        unchanged_benchmark=True, image_edits=False, reserved_va=fixture.LIMIT,
        score_eligible=False, standard_suite=False, gameplay_ipc=None))
    print(json.dumps([dict(seed=row['seed'], iterations=row['iterations'],
                          expected_crc=row['expected_crc']) for row in results]))


if __name__ == '__main__':
    main()
