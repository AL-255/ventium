#!/usr/bin/env python3
"""Native x87 + pinned QEMU arithmetic vectors, with exact rational C1 checks.

No RTL, saved state or host floating-point operation supplies expected C1.
This is a bounded correctness fixture, not a performance benchmark.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import random
import struct
import subprocess
import unittest

from run_srt_c1_observe import fraction, fx, sha

OPS = {'add': (0, 0xc1), 'mul': (1, 0xc9),
       'sub': (4, 0xe1), 'rsub': (5, 0xe9)}


def exact(case):
    a, b = fraction(case['a']), fraction(case['b'])
    return {'add': lambda: a+b, 'mul': lambda: a*b,
            'sub': lambda: a-b, 'rsub': lambda: b-a}[case['op']]()


def classify(case, value):
    e, r = exact(case), fraction(value)
    assert not r or not e or (r < 0) == (e < 0)
    return int(abs(r) > abs(e)), int(r != e)


def cases():
    one = fx(0, 16383, 1 << 63)
    two = fx(0, 16384, 1 << 63)
    pairs = [(one, two), (one, one), (one, one ^ (1 << 79)),
             (one, fx(0, 16320, 1 << 63)),
             (one, fx(0, 16359, 1 << 63)),
             (one, fx(0, 16330, 1 << 63)),
             (one+0x18000000000, one+0xc00),
             (fx(0, 16383, (1 << 64)-1), one+1)]
    rng = random.Random(0xA1C1_1010)
    pairs += [(fx(rng.randrange(2), 16368+rng.randrange(32),
                  (1 << 63) | rng.getrandbits(63)),
               fx(rng.randrange(2), 16368+rng.randrange(32),
                  (1 << 63) | rng.getrandbits(63))) for _ in range(4)]
    return [dict(op=op, pc=pc, rc=rc, seed=seed, a=a, b=b)
            for pc in (0, 2, 3) for rc in range(4) for seed in (0, 1)
            for a, b in pairs for op in OPS]


def assembly(items):
    code = ['.section .text', '.globl _start', '_start:']
    data = ['.section .data', '.balign 4', 'env: .space 28',
            f'words: .space {len(items)*16}']
    for i, c in enumerate(items):
        # Exact register encodings avoid assembler dialect ambiguity for SUBR.
        code += ['fninit', f'fldcw cw_{i}', f'fldt b_{i}', f'fldt a_{i}',
                 'fnstenv env', 'andw $0xfdff,env+4']
        if c['seed']:
            code += ['orw $0x0200,env+4']
        code += ['fldenv env', f'fnstsw words+{i*16}',
                 f'.byte 0xd8, 0x{OPS[c["op"]][1]:02x}',
                 f'fnstsw words+{i*16+2}', f'fstpt words+{i*16+4}']
        data += [f'cw_{i}: .word {0x7f | c["pc"] << 8 | c["rc"] << 10}']
        for name in ('a', 'b'):
            data += [f'{name}_{i}: .quad {c[name] & ((1 << 64)-1)}',
                     f'.word {c[name] >> 64}']
    code += ['movl $4,%eax', 'movl $1,%ebx', 'movl $words,%ecx',
             f'movl ${len(items)*16},%edx', 'int $0x80',
             'movl $1,%eax', 'xorl %ebx,%ebx', 'int $0x80']
    return '\n'.join(code+data)+'\n'


def generate(out):
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = out.resolve()
    assert out.is_relative_to(scratch) and not out.exists()
    out.mkdir()
    qemu = repo/'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386'
    pins = {str(p): sha(p) for p in [Path(__file__),
            Path(__file__).with_name('run_srt_c1_observe.py'), qemu]}
    items = cases()
    (out/'probe.S').write_text(assembly(items))
    (out/'cases.json').write_text(json.dumps(items, indent=2)+'\n')
    runs = []

    def run(name, cmd):
        p = subprocess.run(list(map(str, cmd)), env={**os.environ, 'TMPDIR': str(scratch)},
                           capture_output=True, timeout=30)
        (out/(name+'.stdout')).write_bytes(p.stdout)
        (out/(name+'.stderr')).write_bytes(p.stderr)
        runs.append(dict(name=name, argv=list(map(str, cmd)), status=p.returncode))
        assert p.returncode == 0, (name, p.stderr[-1000:])
        return p.stdout

    run('assemble', ['as', '--32', out/'probe.S', '-o', out/'probe.o'])
    run('link', ['ld', '-m', 'elf_i386', '-Ttext', '0x08048000',
                 '-o', out/'probe.elf', out/'probe.o'])
    streams = dict(native=run('native', [out/'probe.elf']),
                   qemu=run('qemu', [qemu, '-cpu', 'pentium', out/'probe.elf']))
    assert all(len(s) == len(items)*16 for s in streams.values())
    rows = []
    with (out/'vectors.txt').open('x') as f:
        for i, c in enumerate(items):
            values = {}
            for name, stream in streams.items():
                before, after = struct.unpack_from('<HH', stream, i*16)
                value = int.from_bytes(stream[i*16+4:i*16+14], 'little')
                assert ((before >> 9) & 1) == c['seed']
                values[name] = dict(value=value, before=before, after=after)
            n, q = values['native'], values['qemu']
            assert n['value'] == q['value'], (i, c, values)
            c1, pe = classify(c, n['value'])
            assert ((n['after'] >> 9) & 1) == c1, (i, c, values, c1)
            assert ((n['after'] >> 5) & 1) == pe, (i, c, values, pe)
            f.write(f'{OPS[c["op"]][0]:x} {c["pc"]:x} {c["rc"]:x} '
                    f'{c["seed"]:x} {c["a"]:020x} {c["b"]:020x} '
                    f'{c1:x} {n["value"]:020x}\n')
            rows.append(dict(case=c, observers=values, exact_c1=c1, exact_pe=pe))
    assert all(sha(p) == h for p, h in pins.items())
    result = dict(cases=len(items), passed=True, native_exact_c1_pe=True,
                  qemu_value_equal=True, vectors_sha256=sha(out/'vectors.txt'),
                  pins=pins, runs=runs, observations=rows, rtl_tested=False)
    (out/'oracle.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('observations', 'pins', 'runs')}))


class OracleTests(unittest.TestCase):
    def test_exact_operations(self):
        a, b = fx(0, 16384, 1 << 63), fx(0, 16383, 1 << 63)
        for op, want in [('add', 3), ('mul', 2), ('sub', 1), ('rsub', -1)]:
            self.assertEqual(exact(dict(op=op, a=a, b=b)), Fraction(want))

    def test_direction_magnitude(self):
        one = fx(0, 16383, 1 << 63)
        c = dict(op='add', a=one, b=fx(0, 16318, 1 << 63))
        self.assertEqual(classify(c, one), (0, 1))
        self.assertEqual(classify(c, one+1), (1, 1))
        c['a'] ^= 1 << 79
        c['b'] ^= 1 << 79
        self.assertEqual(classify(c, one ^ (1 << 79)), (0, 1))
        self.assertEqual(classify(c, (one+1) ^ (1 << 79)), (1, 1))

    def test_corpus(self):
        items = cases()
        self.assertEqual(len(items), 1152)
        self.assertEqual(items, cases())
        self.assertEqual(len({(c['pc'], c['rc'], c['seed'], c['op']) for c in items}), 96)
        code = assembly(items)
        self.assertEqual(code.count('fldenv env'), len(items))
        self.assertEqual(code.count('.byte 0xd8,'), len(items))
        self.assertIn('movl $18432,%edx', code)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path)
    args = ap.parse_args()
    if args.out is None:
        unittest.main(argv=['arith_c1_vectors'])
    else:
        generate(args.out)
