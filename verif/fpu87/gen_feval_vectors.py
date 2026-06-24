#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# gen_feval_vectors.py — x87 add/sub/mul/subr vectors + golden (ven_fpu_oracle),
# now PRECISION-CONTROL aware. Each vector carries a pc (x87 fctrl[9:8]: 0=24-bit
# single, 2=53-bit double, 3=64-bit extended); the golden is computed by the
# oracle with extF80_roundingPrecision set to match (FPU_PREC env), so the gate
# tests the PC=24/53 path Quake actually runs under (the board-F5 bug). Default
# mix favors PC=24 (single) since that is Quake's setting.
#
# Vector line: <sub> <rc> <pc> <a80> <b80> <golden80> <xsw6>
# Usage: gen_feval_vectors.py <ven_fpu_oracle_bin> <out_file> <count> <seed> [pcmix]
#   pcmix: "mix" (default, all three) | "24" | "53" | "64"
import sys, os, random, subprocess

M64 = (1 << 64) - 1
def f80(sign, exp, sig): return "%04x%016x" % ((((sign & 1) << 15) | (exp & 0x7FFF)), sig & M64)

def normal(r):  return f80(r.getrandbits(1), r.randint(1, 0x7FFE), (1 << 63) | r.getrandbits(63))
def denormal(r):
    s = r.getrandbits(63); return f80(r.getrandbits(1), 0, s if s else 1)
def zero(r):    return f80(r.getrandbits(1), 0, 0)
def inf(r):     return f80(r.getrandbits(1), 0x7FFF, 1 << 63)
def nan(r):     return f80(r.getrandbits(1), 0x7FFF, (1 << 63) | r.getrandbits(62) | 1)

def operand(r):
    k = r.random()
    if   k < 0.74: return normal(r)
    elif k < 0.86: return denormal(r)
    elif k < 0.93: return zero(r)
    elif k < 0.97: return inf(r)
    else:          return nan(r)

def near_cancel(r):
    exp = r.randint(0x3F00, 0x4100)
    ma = (1 << 63) | r.getrandbits(63)
    mb = ma ^ (r.getrandbits(r.randint(1, 40)))
    sa = r.getrandbits(1); sb = sa ^ 1 if r.random() < 0.7 else sa
    return f80(sa, exp, ma), f80(sb, exp, mb)

PC2PREC = {0: 24, 2: 53, 3: 64}      # x87 fctrl[9:8] -> significand bits

def oline(sub, rc, a, b):
    if sub == 0: return "add %d %s %s" % (rc, a, b)
    if sub == 1: return "mul %d %s %s" % (rc, a, b)
    if sub == 4: return "sub %d %s %s" % (rc, a, b)
    return "sub %d %s %s" % (rc, b, a)               # subr: b - a

def main():
    oracle, out, count, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    pcmix = sys.argv[5] if len(sys.argv) > 5 else "mix"
    r = random.Random(seed)
    pcset = {"24": [0], "53": [2], "64": [3]}.get(pcmix, [0, 0, 2, 3])  # mix biases to PC=24

    rows = []  # (sub, rc, pc, a, b)
    while len(rows) < count:
        a, b = near_cancel(r) if r.random() < 0.25 else (operand(r), operand(r))
        rows.append((r.choice([0, 1, 4, 5]), r.randint(0, 3), r.choice(pcset), a, b))
    rows = rows[:count]

    # group by pc so the oracle runs once per precision (env is per-process)
    golden = {}
    for pc in set(row[2] for row in rows):
        idx = [i for i, row in enumerate(rows) if row[2] == pc]
        inp = "".join(oline(rows[i][0], rows[i][1], rows[i][3], rows[i][4]) + "\n" for i in idx)
        env = dict(os.environ, FPU_PREC=str(PC2PREC[pc]))
        res = subprocess.run([oracle], input=inp, capture_output=True, text=True, env=env).stdout.strip().split("\n")
        if len(res) != len(idx):
            sys.stderr.write("oracle gave %d lines for %d (pc=%d)\n" % (len(res), len(idx), pc)); sys.exit(2)
        for j, i in enumerate(idx):
            golden[i] = res[j]

    with open(out, "w") as fo:
        for i, (sub, rc, pc, a, b) in enumerate(rows):
            parts = golden[i].split()
            g, xsw = (parts[0], parts[1]) if len(parts) >= 2 else (parts[0], "00")
            fo.write("%d %d %d %s %s %s %s\n" % (sub, rc, pc, a, b, g, xsw))
    sys.stderr.write("wrote %d f_eval vectors (pcmix=%s) -> %s\n" % (len(rows), pcmix, out))

if __name__ == "__main__":
    main()
