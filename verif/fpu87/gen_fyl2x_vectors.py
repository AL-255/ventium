#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# gen_fyl2x_vectors.py — FYL2X (y*log2(x)) vectors + qref golden, for the OOC
# characterization gate. Domain: x>0 (else invalid), y any finite. Emphasizes
# x near 1.0 (log2~0, the Quake-normalized regime) plus a broad exponent spread.
# qref is called per-vector (single-shot, operands split se+fr).
#
# Usage: gen_fyl2x_vectors.py <qref_bin> <out_file> <count> <seed>
import sys, random, subprocess

M64 = (1 << 64) - 1
def x80(sign, exp, sig): return "%04x%016x" % ((((sign & 1) << 15) | (exp & 0x7FFF)), sig & M64)
def split(h): return h[:4], h[4:]

def y_op(r):
    s = r.getrandbits(1); ue = r.randint(-20, 40)
    return x80(s, ue + 16383, (1 << 63) | r.getrandbits(63))

def x_op(r):                                   # x > 0
    k = r.random()
    if k < 0.45:                               # near 1.0 (log2 small) -> exp 0x3ffe..0x4000
        return x80(0, r.randint(0x3FF0, 0x4010), (1 << 63) | r.getrandbits(63))
    ue = r.randint(-30, 40)
    return x80(0, ue + 16383, (1 << 63) | r.getrandbits(63))

def main():
    qref, out, count, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    r = random.Random(seed)
    n_ok = 0
    with open(out, "w") as fo:
        for _ in range(count):
            rc = 0                              # qref single-shot is RNE
            y = y_op(r); x = x_op(r)
            yse, yfr = split(y); xse, xfr = split(x)
            try:
                o = subprocess.run([qref, "fyl2x", yse, yfr, xse, xfr],
                                   capture_output=True, text=True, check=True).stdout.strip()
                g = o.split()[0]
                if len(g) != 20: continue
            except Exception:
                continue
            fo.write("%d %s %s %s\n" % (rc, y, x, g)); n_ok += 1
    sys.stderr.write("wrote %d fyl2x vectors -> %s\n" % (n_ok, out))

if __name__ == "__main__":
    main()
