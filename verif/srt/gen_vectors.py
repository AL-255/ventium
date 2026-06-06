#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Emit golden vectors for the SRT Verilator gate, from the single-source model.
import sys, os, struct, random
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tools', 'srt'))
import srt_model as sm
OUT = sys.argv[1] if len(sys.argv) > 1 else "build/srt"
os.makedirs(OUT, exist_ok=True)
def h80(v): return f"{v & ((1<<80)-1):020X}"
vecs = [
    (4195835.0, 3145727.0),   # canonical FDIV pair (D=23 bad column) -> flaws
    (7654321.0, 3145727.0),   # triggering divisor, NON-published pair -> clean
    (4195835.0, 3.0),         # non-triggering divisor -> clean
    (5505001.0, 294911.0),    # another widely-quoted FDIV pair
    (1.875, 1.0), (7.0, 5.0), (355.0, 113.0), (2.0, 3.0), (1.0, 1.0),
]
random.seed(20240611)
for _ in range(600):
    vecs.append((float(random.randint(1<<20,(1<<24)-1)),
                 float(random.randint(1<<20,(1<<24)-1))))
fa, fb = open(f"{OUT}/vec_a.hex","w"), open(f"{OUT}/vec_b.hex","w")
fc, fd = open(f"{OUT}/vec_ec.hex","w"), open(f"{OUT}/vec_eb.hex","w")
for a, b in vecs:
    fa.write(h80(sm.double_to_fx80(a))+"\n"); fb.write(h80(sm.double_to_fx80(b))+"\n")
    fc.write(h80(sm.fdiv_fx80(a,b,False))+"\n"); fd.write(h80(sm.fdiv_fx80(a,b,True))+"\n")
for f in (fa,fb,fc,fd): f.close()
print(len(vecs))
