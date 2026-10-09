#!/usr/bin/env python3
"""Observe FSQRT/FDIV C1 against native x87 and exact integer arithmetic.

This uses an existing UV-fast model, not a new compile or performance run.
FLDENV deliberately seeds C1 through the ISA in a directed test; there are no
debugger register writes, post-init snapshots, comparator changes or guest hacks.
Only finite non-overflowing results are covered. Native x87 is not P54 silicon.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import random
import re
import socket
import struct
import subprocess
import sys
import time


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def fx(sign, exp, mantissa):
    return (sign << 79) | (exp << 64) | mantissa


def fraction(bits):
    sign, exp, mantissa = bits >> 79, (bits >> 64) & 0x7fff, bits & ((1 << 64)-1)
    assert exp != 0x7fff, 'nonfinite outside this witness'
    assert exp == 0 or mantissa >> 63, 'unnormal outside this witness'
    power = max(1, exp) - 16383 - 63
    val = Fraction(mantissa << max(0, power), 1 << max(0, -power))
    return -val if sign else val


def classify(case, result):
    """Exact comparison with the unrounded mathematical magnitude, no FP math."""
    a, r = fraction(case['a']), fraction(result)
    if case['op'] == 'sqrt':
        assert a >= 0 and r >= 0
        got, exact = r*r, a
    else:
        b = fraction(case['b'])
        assert b != 0
        assert not r or (r < 0) == ((a < 0) != (b < 0))
        got, exact = abs(r*b), abs(a)
    return {'c1': int(got > exact), 'inexact': int(got != exact)}


def cases():
    one = 0x8000000000000000
    rng = random.Random(0xC1F5_2026)
    sq = [fx(0, 0x3fff, one), fx(0, 0x4000, one), fx(0, 0x4001, one),
          fx(0, 0x3fff, one+1), fx(0, 0x3fff, one+0x8000000000),
          fx(0, 0x3fff, one+0x400), fx(0, 1, one),
          fx(0, 0, 1), fx(0, 0x7ffe, (1 << 64)-1), fx(0, 0, 0)]
    sq += [fx(0, 0x3ff0+rng.randrange(32), one | rng.getrandbits(63)) for _ in range(8)]
    dv = [(fx(0, 0x3fff, one), fx(0, 0x4000, one)),
          (fx(0, 0x3fff, one), fx(0, 0x4000, 0xc000000000000000)),
          (fx(0, 0x4000, one), fx(0, 0x4000, 0xc000000000000000)),
          (fx(0, 0x3fff, (1 << 64)-1), fx(0, 0x3fff, one)),
          # Exact halfway cases at PC24 and PC53 (even and odd retained LSB).
          (fx(0, 0x3fff, one+0x8000000000), fx(0, 0x3fff, one)),
          (fx(0, 0x3fff, one+0x18000000000), fx(0, 0x3fff, one)),
          (fx(0, 0x3fff, one+0x400), fx(0, 0x3fff, one)),
          (fx(0, 0x3fff, one+0xc00), fx(0, 0x3fff, one))]
    dv += [(a ^ (1 << 79), b) for a, b in list(dv)]
    dv += [(fx(0, 0x3ff0+rng.randrange(32), one | rng.getrandbits(63)),
            fx(0, 0x3ff0+rng.randrange(32), one | rng.getrandbits(63))) for _ in range(4)]
    return [dict(op=op, a=a, b=b, pc=pc, rc=rc, seed=seed)
            for pc in (0, 2, 3) for rc in range(4) for seed in (0, 1)
            for op, operands in [('sqrt', [(a, 0) for a in sq]), ('div', dv)]
            for a, b in operands]


def assembly(items):
    code = ['.section .text', '.globl _start', '_start:']
    data = ['.section .data', '.balign 4', 'env: .space 28', 'words:']
    data += [f'.space {16*len(items)}']
    for i, c in enumerate(items):
        code += ['fninit', f'fldcw cw_{i}']
        if c['op'] == 'div':
            code += [f'fldt b_{i}']
        code += [f'fldt a_{i}', 'fnstenv env', 'andw $0xfdff,env+4']
        if c['seed']:
            code += ['orw $0x0200,env+4']
        code += ['fldenv env', f'fnstsw words+{i*16}',
                 'fsqrt' if c['op'] == 'sqrt' else 'fdiv %st(1),%st(0)',
                 f'fnstsw words+{i*16+2}', f'fstpt words+{i*16+4}']
        data += [f'cw_{i}: .word {0x7f | c["pc"] << 8 | c["rc"] << 10}']
        for name in ('a', 'b'):
            data += [f'{name}_{i}: .quad {c[name] & ((1<<64)-1)}',
                     f'.word {c[name] >> 64}']
    code += ['movl $4,%eax', 'movl $1,%ebx', 'movl $words,%ecx',
             f'movl ${16*len(items)},%edx', 'int $0x80', 'movl $1,%eax',
             'xorl %ebx,%ebx', 'int $0x80']
    return '\n'.join(code+data)+'\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--model', type=Path, required=True)
    ap.add_argument('--model-sha256', required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert out.is_relative_to(scratch) and not out.exists()
    assert sha(args.model) == args.model_sha256
    out.mkdir()
    qemu = (repo/'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386').resolve()
    generator = repo/'verif/qemu-trace/gen_trace.py'
    pins = {str(p): sha(p) for p in [Path(__file__), args.model, qemu, generator,
                                     repo/'verif/diff/tracefmt.py']}
    env = {k:v for k,v in os.environ.items()
           if not k.startswith(('VEN_', 'TB_', 'QEMU_', 'AXI_', 'VTM_'))}
    env['TMPDIR'] = str(scratch)
    runs = []

    def run(name, cmd):
        start = time.monotonic()
        p = subprocess.run(list(map(str, cmd)), env=env, capture_output=True, timeout=90)
        (out/(name+'.stdout')).write_bytes(p.stdout)
        (out/(name+'.stderr')).write_bytes(p.stderr)
        runs.append(dict(name=name, argv=list(map(str,cmd)), status=p.returncode,
                         seconds=time.monotonic()-start))
        assert p.returncode == 0, (name, p.returncode, p.stderr[-2000:])
        return p.stdout

    items = cases()
    (out/'cases.json').write_text(json.dumps(items, indent=2)+'\n')
    (out/'probe.S').write_text(assembly(items))
    run('assemble', ['as', '--32', out/'probe.S', '-o', out/'probe.o'])
    run('link', ['ld', '-m', 'elf_i386', '-Ttext', '0x08048000', '-o', out/'probe.elf', out/'probe.o'])
    native = run('native', [out/'probe.elf'])
    golden = run('qemu', [qemu, '-cpu', 'pentium', out/'probe.elf'])
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    run('entry', [sys.executable, '-B', generator, '--qemu', qemu, '--elf', out/'probe.elf',
                  '--syscall-proxy', '--image-out', out/'entry.image.json', '--out', out/'entry.vtrace',
                  '--max-insn', '0', '--port', str(port)])
    assert len((out/'entry.vtrace').read_text().splitlines()) == 1
    run('rtl', [args.model, '--quake-image', out/'entry.image.json', '--emulate-syscalls',
                '--x87', '--cycle-func', '--max-insn', '50000', '--max-cycles', '2000000',
                '--out', out/'rtl.vtrace', '--user-stdout', out/'guest.stdout'])
    log = (out/'rtl.stderr').read_text()
    assert 'tb: stop: FREE-RUN guest exit_group(0)' in log
    assert '[fault-deliveries] actual=0' in log
    pairing = re.search(r'pairedV=(\d+)', (out/'rtl.stdout').read_text())
    assert pairing and int(pairing[1]) > 0
    streams = {'native': native, 'qemu': golden, 'rtl': (out/'guest.stdout').read_bytes()}
    assert all(len(s) == len(items)*16 for s in streams.values())
    findings = []
    for i, c in enumerate(items):
        row = dict(index=i, case=c, observers={})
        for name, stream in streams.items():
            before, after = struct.unpack_from('<HH', stream, 16*i)
            value = int.from_bytes(stream[16*i+4:16*i+14], 'little')
            assert bool(before & 0x200) == bool(c['seed']), (i, name, 'C1 seed not loaded')
            result = classify(c, value)
            row['observers'][name] = dict(before=before, after=after, value=f'{value:020x}',
                observed_c1=(after >> 9) & 1, **result)
        n = row['observers']['native']
        assert n['observed_c1'] == n['c1'], ('native vs exact arithmetic', row)
        row['value_matches_native'] = all(o['value'] == n['value'] for o in row['observers'].values())
        row['rtl_c1_correct'] = row['observers']['rtl']['observed_c1'] == row['observers']['rtl']['c1']
        findings.append(row)
    assert all(sha(p) == h for p, h in pins.items())
    result = dict(kind='SRT_C1_DIAGNOSTIC', model=args.model_sha256, cases=len(items),
        value_mismatches=sum(not r['value_matches_native'] for r in findings),
        rtl_c1_mismatches=sum(not r['rtl_c1_correct'] for r in findings),
        native_exact_c1_all_match=True, v_retirements=int(pairing[1]),
        invocations=runs, pins=pins, findings=findings, standard_suite=False,
        whole_instruction_differential=False, gameplay_ipc=None)
    (out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins', 'invocations', 'findings')}))
    return int(bool(result['value_mismatches'] or result['rtl_c1_mismatches']))


if __name__ == '__main__':
    sys.exit(main())
