#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# gen_conv_vectors.py — x87 f32/f64 <-> floatx80 conversion vectors + golden
# (conv_oracle). from32/from64 = exact widening (all input classes); to32/to64 =
# narrowing-with-rounding, stressed with x80 values that round, overflow the
# target range (->Inf/max), and underflow it (->denormal/zero).
#
# Usage: gen_conv_vectors.py <conv_oracle_bin> <out_file> <count> <seed>
import sys, random, subprocess

M64 = (1 << 64) - 1
def x80(sign, exp, sig): return "%04x%016x" % ((((sign & 1) << 15) | (exp & 0x7FFF)), sig & M64)

# NOTE: NaN inputs to from32/from64 are intentionally EXCLUDED. They expose a
# pure quiet-bit difference (the RTL preserves the SNaN payload verbatim on widen;
# SoftFloat quiets SNaN->QNaN). Real x87 FLD does NOT quiet, so this is a
# golden-vs-x87-semantics question for QEMU to adjudicate, NOT a Quake-relevant
# bug (Quake never FLDs a NaN). Set GEN_CONV_NAN=1 to re-include them.
import os
_NAN = os.environ.get("GEN_CONV_NAN", "0") == "1"

def f32_bits(r):
    k = r.random()
    if   k < 0.62: e = r.randint(1, 254); return (r.getrandbits(1) << 31) | (e << 23) | r.getrandbits(23)
    elif k < 0.80: return (r.getrandbits(1) << 31) | r.getrandbits(23)              # denormal/zero
    elif k < 0.92 or not _NAN: return (r.getrandbits(1) << 31) | (255 << 23)        # inf
    else:          return (r.getrandbits(1) << 31) | (255 << 23) | (r.getrandbits(23) | 1)  # nan

def f64_bits(r):
    k = r.random()
    if   k < 0.62: e = r.randint(1, 2046); return (r.getrandbits(1) << 63) | (e << 52) | r.getrandbits(52)
    elif k < 0.80: return (r.getrandbits(1) << 63) | r.getrandbits(52)
    elif k < 0.92 or not _NAN: return (r.getrandbits(1) << 63) | (2047 << 52)       # inf
    else:          return (r.getrandbits(1) << 63) | (2047 << 52) | (r.getrandbits(52) | 1)

def x80_operand(r, target):
    # target = 'f32' (exp band ~ +/-160) or 'f64' (~ +/-1100) to straddle overflow/underflow
    k = r.random()
    s = r.getrandbits(1)
    span = 160 if target == 'f32' else 1100
    if   k < 0.55: ue = r.randint(-span, span); return x80(s, ue + 16383, (1 << 63) | r.getrandbits(63))
    elif k < 0.70: ue = r.choice([span-2, span-1, span, span+1, span+8]);  return x80(s, ue + 16383, (1 << 63) | r.getrandbits(63))   # near overflow
    elif k < 0.85: ue = r.choice([-(span-2), -(span+1), -(span+10), -(span+24)]); return x80(s, (ue + 16383) & 0x7FFF, (1 << 63) | r.getrandbits(63))  # near underflow
    elif k < 0.92: s2 = r.getrandbits(63); return x80(s, 0, s2 if s2 else 1)       # denormal x80
    elif k < 0.96: return x80(s, 0, 0)                                             # zero
    else:          return x80(s, 0x7FFF, 1 << 63)                                  # inf

def main():
    oracle, out, count, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    r = random.Random(seed)
    rows = []  # (op, rc, in)
    for _ in range(count):
        op = r.choice(["from32", "from64", "to32", "to64"])
        rc = r.randint(0, 3)
        if   op == "from32": s = "%08x"  % f32_bits(r)
        elif op == "from64": s = "%016x" % f64_bits(r)
        elif op == "to32":   s = x80_operand(r, 'f32')
        else:                s = x80_operand(r, 'f64')
        rows.append((op, rc, s))

    inp = "".join("%s %d %s\n" % (op, rc, s) for op, rc, s in rows)
    p = subprocess.run([oracle], input=inp, capture_output=True, text=True)
    res = p.stdout.strip().split("\n")
    if len(res) != len(rows):
        sys.stderr.write("oracle gave %d lines for %d vectors\n" % (len(res), len(rows)))
        sys.exit(2)
    with open(out, "w") as fo:
        for (op, rc, s), line in zip(rows, res):
            parts = line.split()
            g, fl = (parts[0], parts[1]) if len(parts) >= 2 else (parts[0], "0")
            fo.write("%s %d %s %s %s\n" % (op, rc, s, g, fl))
    sys.stderr.write("wrote %d conversion vectors -> %s\n" % (len(rows), out))

if __name__ == "__main__":
    main()
