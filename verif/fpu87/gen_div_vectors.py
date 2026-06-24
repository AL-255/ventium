#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# gen_div_vectors.py — finite floatx80 divide vectors + golden, PRECISION-CONTROL
# aware (the iterative SRT engine OWNS the result; pc=fctrl[9:8] rounds it to
# 24/53/64-bit). Vector line: <rc> <pc> <a80> <b80> <golden80> <xsw>. Golden from
# the SoftFloat oracle with extF80_roundingPrecision set per pc (FPU_PREC env).
# Operands = the engine's domain: finite normals/denormals/extreme-exp + single
# zeros (no Inf/NaN/0-over-0). pcmix biases to PC=24 (Quake's setting).
#
# Usage: gen_div_vectors.py <oracle_bin> <out_file> <count> <seed> [pcmix]
import sys, os, random, subprocess

M64 = (1 << 64) - 1
def f80(sign, exp, sig): return "%04x%016x" % ((((sign & 1) << 15) | (exp & 0x7FFF)), sig & M64)
def normal(r):  return r.getrandbits(1), r.randint(1, 0x7FFE), (1 << 63) | r.getrandbits(63)
def extreme(r): return r.getrandbits(1), r.choice([1,2,3,4,0x7FFA,0x7FFB,0x7FFC,0x7FFD,0x7FFE]), (1 << 63) | r.getrandbits(63)
def denormal(r):
    sig = r.getrandbits(63); return r.getrandbits(1), 0, (sig if sig else 1)
def zero(r):    return r.getrandbits(1), 0, 0
def operand(r):
    k = r.random()
    if   k < 0.50: s,e,g = normal(r)
    elif k < 0.72: s,e,g = extreme(r)
    elif k < 0.90: s,e,g = denormal(r)
    else:          s,e,g = zero(r)
    return f80(s,e,g), (e==0 and g==0)
PC2PREC = {0: 24, 2: 53, 3: 64}

def main():
    oracle, out, count, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    pcmix = sys.argv[5] if len(sys.argv) > 5 else "mix"
    r = random.Random(seed)
    pcset = {"24": [0], "53": [2], "64": [3]}.get(pcmix, [0, 0, 2, 3])
    rows = []  # (rc, pc, a, b)
    while len(rows) < count:
        a, az = operand(r); b, bz = operand(r)
        if az and bz: continue
        rows.append((r.randint(0,3), r.choice(pcset), a, b))
    rows = rows[:count]

    golden = {}
    for pc in set(row[1] for row in rows):
        idx = [i for i,row in enumerate(rows) if row[1]==pc]
        inp = "".join("div %d %s %s\n" % (rows[i][0], rows[i][2], rows[i][3]) for i in idx)
        env = dict(os.environ, FPU_PREC=str(PC2PREC[pc]))
        res = subprocess.run([oracle], input=inp, capture_output=True, text=True, env=env).stdout.strip().split("\n")
        if len(res) != len(idx):
            sys.stderr.write("oracle gave %d for %d (pc=%d)\n" % (len(res), len(idx), pc)); sys.exit(2)
        for j,i in enumerate(idx): golden[i] = res[j]

    with open(out, "w") as fo:
        for i,(rc,pc,a,b) in enumerate(rows):
            parts = golden[i].split()
            g, xsw = (parts[0], parts[1]) if len(parts)>=2 else (parts[0], "00")
            fo.write("%d %d %s %s %s %s\n" % (rc, pc, a, b, g, xsw))
    sys.stderr.write("wrote %d div vectors (pcmix=%s) -> %s\n" % (len(rows), pcmix, out))

if __name__ == "__main__":
    main()
