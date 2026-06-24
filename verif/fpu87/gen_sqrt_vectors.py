#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# gen_sqrt_vectors.py — floatx80 FSQRT vectors + golden (ven_fpu_oracle sqrt) for
# the standalone SRT-engine OOC gate (tb_srt_div.cpp in sqrt mode). The engine
# assumes a >= 0 (negatives -> IE handled elsewhere), so we emit only NON-NEGATIVE
# finite operands (normals + denormals), +0, and +Inf. Vector format matches the
# divider gate: "<rc> <a80> <b80> <golden80> <xsw>" (b is a dummy, ignored by sqrt).
#
# Usage: gen_sqrt_vectors.py <ven_fpu_oracle_bin> <out_file> <count> <seed>
import sys, os, random, subprocess

M64 = (1 << 64) - 1
DUMMY_B = "3fff8000000000000000"   # +1.0, ignored by the sqrt path
PC2PREC = {0: 24, 2: 53, 3: 64}

def f80(exp, sig):                 # sign always 0 (non-negative)
    return "%04x%016x" % (exp & 0x7FFF, sig & M64)

def operand(r):
    k = r.random()
    if   k < 0.62: return f80(r.randint(1, 0x7FFE), (1 << 63) | r.getrandbits(63))   # normal
    elif k < 0.80:                                                                    # extreme exp
        return f80(r.choice([1, 2, 3, 0x7FFA, 0x7FFC, 0x7FFE]), (1 << 63) | r.getrandbits(63))
    elif k < 0.92:                                                                    # denormal
        s = r.getrandbits(63); return f80(0, s if s else 1)
    elif k < 0.97: return f80(0, 0)                                                   # +0
    else:          return f80(0x7FFF, 1 << 63)                                        # +Inf

def main():
    oracle, out, count, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    pcmix = sys.argv[5] if len(sys.argv) > 5 else "mix"
    r = random.Random(seed)
    pcset = {"24": [0], "53": [2], "64": [3]}.get(pcmix, [0, 0, 2, 3])
    rows = [(r.randint(0, 3), r.choice(pcset), operand(r)) for _ in range(count)]   # (rc, pc, a)
    golden = {}
    for pc in set(row[1] for row in rows):
        idx = [i for i, row in enumerate(rows) if row[1] == pc]
        inp = "".join("sqrt %d %s\n" % (rows[i][0], rows[i][2]) for i in idx)
        env = dict(os.environ, FPU_PREC=str(PC2PREC[pc]))
        res = subprocess.run([oracle], input=inp, capture_output=True, text=True, env=env).stdout.strip().split("\n")
        if len(res) != len(idx):
            sys.stderr.write("oracle gave %d for %d (pc=%d)\n" % (len(res), len(idx), pc)); sys.exit(2)
        for j, i in enumerate(idx): golden[i] = res[j]
    with open(out, "w") as fo:
        for i, (rc, pc, a) in enumerate(rows):
            parts = golden[i].split()
            g, xsw = (parts[0], parts[1]) if len(parts) >= 2 else (parts[0], "00")
            fo.write("%d %d %s %s %s %s\n" % (rc, pc, a, DUMMY_B, g, xsw))
    sys.stderr.write("wrote %d sqrt vectors (pcmix=%s) -> %s\n" % (len(rows), pcmix, out))

if __name__ == "__main__":
    main()
