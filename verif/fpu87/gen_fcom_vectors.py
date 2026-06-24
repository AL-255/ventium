#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# gen_fcom_vectors.py — x87 FCOM condition-code vectors with an INDEPENDENT golden
# (floatx80 -> exact rational compare, computed here in Python — no oracle). Codes
# encode {C3,C2,C0}: less=1(001) equal=4(100) greater=0(000) unordered=7(111).
# Stresses the compare edges: equal, near-equal (same exp, perturbed low bits),
# opposite signs, +0/-0, zero-vs-nonzero, denormals, Inf, and NaN(->unordered).
#
# Usage: gen_fcom_vectors.py <out_file> <count> <seed>
import sys, random
from fractions import Fraction

M64 = (1 << 64) - 1
def x80(sign, exp, sig): return "%04x%016x" % ((((sign & 1) << 15) | (exp & 0x7FFF)), sig & M64)

def decode(h):
    se = int(h[:4], 16); sig = int(h[4:], 16)
    sign = se >> 15; e = se & 0x7FFF
    if e == 0x7FFF:
        return ('inf', sign) if sig == (1 << 63) else ('nan', sign)
    if e == 0 and sig == 0:
        return ('num', Fraction(0))
    ee = (1 if e == 0 else e) - 16446          # weight of significand LSB
    v = Fraction(sig) * (Fraction(2) ** ee)
    return ('num', -v if sign else v)

def gold_codes(ha, hb):
    a, b = decode(ha), decode(hb)
    if a[0] == 'nan' or b[0] == 'nan':
        return 7                                # unordered
    def lt(x, y):
        tx, vx = x; ty, vy = y
        if tx == 'inf' and ty == 'inf': return vx == 1 and vy == 0   # -inf < +inf
        if tx == 'inf': return vx == 1          # a=-inf < finite/+inf
        if ty == 'inf': return vy == 0          # a < (+inf)
        return vx < vy
    if lt(a, b): return 1                        # less   -> C0
    if lt(b, a): return 0                        # greater-> 000
    return 4                                     # equal  -> C3

def rnd80(r, allow_nan=True):
    k = r.random(); s = r.getrandbits(1)
    if   k < 0.46: return x80(s, r.randint(1, 0x7FFE), (1 << 63) | r.getrandbits(63))   # normal
    elif k < 0.60: return x80(s, r.randint(0x3F00, 0x4100), (1 << 63) | r.getrandbits(63))  # mid-range
    elif k < 0.72: sg = r.getrandbits(63); return x80(s, 0, sg if sg else 1)            # denormal
    elif k < 0.80: return x80(s, 0, 0)                                                  # zero
    elif k < 0.90: return x80(s, 0x7FFF, 1 << 63)                                       # inf
    elif allow_nan: return x80(s, 0x7FFF, (1 << 63) | r.getrandbits(62) | 1)            # nan
    else: return x80(s, r.randint(1, 0x7FFE), (1 << 63) | r.getrandbits(63))

def perturb(r, h):                              # flip a few low significand bits -> near-equal
    se = h[:4]; sig = int(h[4:], 16)
    sig ^= r.getrandbits(r.randint(1, 20))
    return se + "%016x" % (sig & M64)

def main():
    out, count, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    r = random.Random(seed)
    pairs = []
    while len(pairs) < count:
        k = r.random()
        a = rnd80(r)
        if   k < 0.30: b = rnd80(r)             # independent
        elif k < 0.52: b = a                     # exactly equal
        elif k < 0.74: b = perturb(r, a)         # near-equal (magnitude tie-break)
        elif k < 0.86:                           # same magnitude, opposite sign
            se = int(a[:4], 16) ^ 0x8000; b = "%04x%s" % (se, a[4:])
        else:                                    # zero vs something
            a = x80(r.getrandbits(1), 0, 0); b = rnd80(r)
        pairs.append((a, b))
    pairs = pairs[:count]
    with open(out, "w") as fo:
        for a, b in pairs:
            fo.write("%s %s %d\n" % (a, b, gold_codes(a, b)))
    sys.stderr.write("wrote %d fcom vectors -> %s\n" % (len(pairs), out))

if __name__ == "__main__":
    main()
