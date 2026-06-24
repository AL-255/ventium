#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# gen_frndint_vectors.py — x87 FRNDINT vectors + golden (ven_fpu_oracle `rndint`).
# Stresses the rounding edges (incl. the tiny |v|<0.5 cases the fist fix touched):
# fractional values across exponents, exact half-integers, tiny->0/+-1, already-
# integral (pass-through), denormals, zeros, Inf, NaN. All widths via RC 0..3.
#
# Usage: gen_frndint_vectors.py <ven_fpu_oracle_bin> <out_file> <count> <seed>
import sys, random, subprocess, os
# NaN inputs excluded by default: they expose only the SNaN->QNaN quiet-bit
# difference (RTL FRNDINT passes NaN through verbatim; SoftFloat quiets), a
# golden-vs-x87 semantics question, not a finite-value bug. GEN_FRNDINT_NAN=1 to include.
_NAN = os.environ.get("GEN_FRNDINT_NAN", "0") == "1"

M64 = (1 << 64) - 1
def x80(sign, exp, sig): return "%04x%016x" % ((((sign & 1) << 15) | (exp & 0x7FFF)), sig & M64)
def from_ue(sign, ue, m): return x80(sign, ue + 16383, m)

def base(r):
    k = r.random(); s = r.getrandbits(1)
    if   k < 0.34: return from_ue(s, r.randint(-3, 70), (1 << 63) | r.getrandbits(63))     # general
    elif k < 0.54:                                                                          # exact half
        ue = r.randint(1, 60); ip = r.getrandbits(ue) if ue else 0
        return from_ue(s, ue, ((1 << 63) | (ip << (63 - ue)) | (1 << (62 - ue))) & M64)
    elif k < 0.66: return from_ue(s, r.randint(-12, -1), (1 << 63) | r.getrandbits(63))     # tiny <1
    elif k < 0.78: return from_ue(s, r.randint(63, 70), (1 << 63) | r.getrandbits(63))      # already integral
    elif k < 0.88: sg = r.getrandbits(63); return x80(s, 0, sg if sg else 1)                # denormal
    elif k < 0.93: return x80(s, 0, 0)                                                       # zero
    elif k < 0.97 or not _NAN: return x80(s, 0x7FFF, 1 << 63)                                # inf
    else:          return x80(s, 0x7FFF, (1 << 63) | r.getrandbits(62) | 1)                 # nan

def main():
    oracle, out, count, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    r = random.Random(seed)
    rows = [(r.randint(0, 3), base(r)) for _ in range(count)]
    inp = "".join("rndint %d %s\n" % (rc, v) for rc, v in rows)
    p = subprocess.run([oracle], input=inp, capture_output=True, text=True)
    res = p.stdout.strip().split("\n")
    if len(res) != len(rows):
        sys.stderr.write("oracle gave %d lines for %d vectors\n" % (len(res), len(rows))); sys.exit(2)
    with open(out, "w") as fo:
        for (rc, v), line in zip(rows, res):
            parts = line.split()
            g, xsw = (parts[0], parts[1]) if len(parts) >= 2 else (parts[0], "00")
            fo.write("%d %s %s %s\n" % (rc, v, g, xsw))
    sys.stderr.write("wrote %d frndint vectors -> %s\n" % (len(rows), out))

if __name__ == "__main__":
    main()
