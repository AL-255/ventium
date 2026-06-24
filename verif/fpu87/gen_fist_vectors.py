#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# gen_fist_vectors.py — floatx80 FIST/FISTP test vectors + golden (fist_oracle).
# Stresses the rounding-sensitive cases the live-Quake fist divergence implicates:
# values with fractional parts, EXACT half-integers (RNE even/odd), tiny values
# (round to 0 / +/-1), boundary 2^63, and overflow for narrow widths, across all
# widths {16,32,64} and rounding modes {0..3}.
#
# Usage: gen_fist_vectors.py <fist_oracle_bin> <out_file> <count> <seed>
import sys, random

M64 = (1 << 64) - 1

def f80(sign, exp, sig):
    return "%04x%016x" % ((((sign & 1) << 15) | (exp & 0x7FFF)), sig & M64)

def from_ue(sign, ue, m):           # value = m * 2^(ue-63); m should have bit63 set for normals
    return f80(sign, ue + 16383, m)

def base_value(r):
    k = r.random()
    sign = r.getrandbits(1)
    if k < 0.40:                     # general normal with a fractional part
        ue = r.randint(-3, 70)
        m = (1 << 63) | r.getrandbits(63)
        return from_ue(sign, ue, m)
    if k < 0.62:                     # EXACT half-integer: integer + 0.5 (RNE pivot)
        ue = r.randint(1, 61)
        ip = r.getrandbits(ue) if ue > 0 else 0          # integer bits below bit63
        m = (1 << 63) | (ip << (63 - ue)) | (1 << (62 - ue))
        return from_ue(sign, ue, m & M64)
    if k < 0.74:                     # tiny |v| < 1 -> rounds to 0 / +/-1
        ue = r.randint(-12, -1)
        m = (1 << 63) | r.getrandbits(63)
        return from_ue(sign, ue, m)
    if k < 0.84:                     # near / at the int64 boundary 2^63
        ue = r.choice([62, 63, 64, 65])
        m = (1 << 63) | (r.getrandbits(63) if r.random() < 0.5 else 0)
        return from_ue(sign, ue, m)
    if k < 0.92:                     # denormal (rounds to 0 / +/-1)
        sig = r.getrandbits(63)
        return f80(sign, 0, sig if sig else 1)
    if k < 0.96:                     # zero
        return f80(sign, 0, 0)
    if k < 0.98:                     # +/-Inf -> invalid/indefinite
        return f80(sign, 0x7FFF, 1 << 63)
    # NaN -> invalid/indefinite
    return f80(sign, 0x7FFF, (1 << 63) | r.getrandbits(62) | 1)

def main():
    import subprocess
    oracle, out, count, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    r = random.Random(seed)
    rows = []
    while len(rows) < count:
        v = base_value(r)
        # exercise every width x rc on a fraction of values; random on the rest
        if r.random() < 0.25:
            for w in (16, 32, 64):
                for rc in range(4):
                    rows.append((w, rc, v))
        else:
            rows.append((r.choice([16, 32, 64]), r.randint(0, 3), v))
    rows = rows[:count]

    inp = "".join("%d %d %s\n" % (w, rc, v) for w, rc, v in rows)
    p = subprocess.run([oracle], input=inp, capture_output=True, text=True)
    res = p.stdout.strip().split("\n")
    if len(res) != len(rows):
        sys.stderr.write("oracle gave %d lines for %d vectors\n" % (len(res), len(rows)))
        sys.exit(2)
    with open(out, "w") as fo:
        for (w, rc, v), line in zip(rows, res):
            parts = line.split()
            g, fl = (parts[0], parts[1]) if len(parts) >= 2 else (parts[0], "0")
            fo.write("%d %d %s %s %s\n" % (w, rc, v, g, fl))
    sys.stderr.write("wrote %d fist vectors -> %s\n" % (len(rows), out))

if __name__ == "__main__":
    main()
