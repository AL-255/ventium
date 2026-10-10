#!/usr/bin/env python3
"""Exact integer round-pack value/C1 oracle; does not model exception flags.

The old/new RTL miter independently requires all OE/UE/PE bits to stay identical.
This oracle never calls RTL, host floating point, or the legacy rounder.
"""
import argparse
import json
from pathlib import Path
import random
import unittest

BIAS, EMIN, EMAX = 16383, -16382, 16383


def round_value(sign, exponent, sig, sticky, rc, pc):
    assert sign in (0, 1) and rc in range(4) and pc in (0, 2, 3)
    assert 0 <= sig < (1 << 128) and sticky in (0, 1)
    if not sig:
        assert not sticky
        return sign << 79, 0
    precision = {0: 24, 2: 53, 3: 64}[pc]
    # The packer API supplies pre_inexact below the NORMALIZED 128-bit window.
    # Half that window's LSB represents the open interval without changing any
    # rounding decision; tie cases are deliberately on either side of it.
    aligned = sig << (128-sig.bit_length())
    numerator = aligned*2 + sticky
    unit_exp = max(exponent, EMIN) - precision + 1
    shift = exponent - 128 - unit_exp
    if shift >= 0:
        quotient, rem, denominator = numerator << shift, 0, 1
    else:
        denominator = 1 << -shift
        quotient, rem = divmod(numerator, denominator)
    inc = 0
    if rc == 0:
        inc = int(2*rem > denominator or (2*rem == denominator and quotient & 1))
    elif (rc == 1 and sign) or (rc == 2 and not sign):
        inc = int(rem != 0)
    quotient += inc
    out_exp = max(exponent, EMIN)
    if quotient >= (1 << precision):
        assert quotient == 1 << precision
        quotient >>= 1
        out_exp += 1
    if out_exp > EMAX:
        to_inf = rc == 0 or (rc == 1 and sign) or (rc == 2 and not sign)
        if to_inf:
            return (sign << 79) | (0x7fff << 64) | (1 << 63), 1
        return (sign << 79) | (0x7ffe << 64) | (((1 << precision)-1) << (64-precision)), 0
    packed_exp = out_exp + BIAS if quotient >= (1 << (precision-1)) else 0
    return (sign << 79) | (packed_exp << 64) | (quotient << (64-precision)), inc


def vectors():
    rng = random.Random(0xC1_2026_1010)
    exponents = [-16500, -16446, -16445, -16444, -16384, -16383, -16382,
                 -16381, -1, 0, 1, 16382, 16383, 16384, 16500]
    for pc, precision in ((0, 24), (2, 53), (3, 64)):
        half = 1 << (127-precision)
        values = [0, 1 << 127, (1 << 128)-1, (1 << 127)+1,
                  (1 << 127)+half-1, (1 << 127)+half, (1 << 127)+half+1,
                  (1 << 127)+3*half-1, (1 << 127)+3*half, (1 << 127)+3*half+1]
        values += [(1 << 127) | rng.getrandbits(127) for _ in range(8)]
        for sign in (0, 1):
            for rc in range(4):
                for exponent in exponents:
                    for sig in values:
                        for sticky in ((0, 1) if sig else (0,)):
                            args = (sign, exponent, sig, sticky, rc, pc)
                            yield args, round_value(*args)
    # Non-top-aligned inputs exercise the original normalization contract.
    for i in range(3000):
        args = (rng.randrange(2), rng.randrange(-16510, 16400),
                rng.getrandbits(rng.randrange(1, 129)) or 1,
                rng.randrange(2), rng.randrange(4), (0, 2, 3)[i % 3])
        yield args, round_value(*args)


class OracleTests(unittest.TestCase):
    def test_exact_one(self):
        for pc in (0, 2, 3):
            for rc in range(4):
                self.assertEqual(round_value(0, 0, 1 << 127, 0, rc, pc),
                                 (0x3fff8000000000000000, 0))

    def test_nearest_even_both_ties(self):
        top, half = 1 << 127, 1 << 103
        self.assertEqual(round_value(0, 0, top+half, 0, 0, 0), (0x3fff8000000000000000, 0))
        self.assertEqual(round_value(0, 0, top+3*half, 0, 0, 0), (0x3fff8000020000000000, 1))
        self.assertEqual(round_value(0, 0, top+half, 1, 0, 0), (0x3fff8000010000000000, 1))

    def test_negative_directed(self):
        x = (1 << 127)+1
        self.assertEqual(round_value(1, 0, x, 0, 1, 3), (0xbfff8000000000000001, 1))
        self.assertEqual(round_value(1, 0, x, 0, 2, 3), (0xbfff8000000000000000, 0))

    def test_zero_and_underflow(self):
        self.assertEqual(round_value(1, 0, 0, 0, 0, 3), (1 << 79, 0))
        self.assertEqual(round_value(0, -16445, 1 << 127, 0, 0, 3), (1, 0))
        self.assertEqual(round_value(0, -16446, 1 << 127, 0, 0, 3), (0, 0))
        self.assertEqual(round_value(0, -16446, 1 << 127, 1, 0, 3), (1, 1))

    def test_carry_and_overflow(self):
        self.assertEqual(round_value(0, 0, (1 << 128)-1, 0, 2, 3),
                         (0x40008000000000000000, 1))
        self.assertEqual(round_value(0, 16383, (1 << 128)-1, 0, 0, 3),
                         (0x7fff8000000000000000, 1))
        self.assertEqual(round_value(0, 16384, 1 << 127, 0, 3, 3),
                         (0x7ffeffffffffffffffff, 0))

    def test_non_aligned(self):
        for n in (0, 7, 63, 90, 127):
            self.assertEqual(round_value(0, 0, 1 << n, 0, 0, 3),
                             (0x3fff8000000000000000, 0))
            self.assertEqual(round_value(0, 0, 1 << n, 1, 2, 3),
                             (0x3fff8000000000000001, 1))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--emit', type=Path)
    args = ap.parse_args()
    if args.emit is None:
        unittest.main(argv=['round_c1_vectors'])
        return
    out = args.emit.resolve()
    assert out.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    count = 0
    with out.open('x') as f:
        for (sign, exp, sig, sticky, rc, pc), (value, c1) in vectors():
            f.write(f'{sign:x} {exp:d} {sig:032x} {sticky:x} {rc:x} {pc:x} {c1:x} {value:020x}\n')
            count += 1
    print(json.dumps(dict(vectors=count, path=str(out), exception_flags_modelled=False)))


if __name__ == '__main__':
    main()
