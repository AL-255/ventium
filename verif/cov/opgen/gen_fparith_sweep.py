#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Generate an x87 FP-ARITHMETIC input sweep (verif/cov/opgen/tests/fparith_sweep):
FADD/FSUB/FMUL/FDIV over many diverse f64 operand pairs (walking-bit mantissas,
diverse exponents, signs, special values) so the SPLIT FP pipeline's stage-1 eval
register (core.sv fpp2_s1, gated on +VEN_FP_PIPE+VEN_SRT_ITER) toggles its mantissa/
exponent bits across diverse results -- not just the handful the ISA suite hits.
Built for the feature TB (obj_dir_cov_feat); run by the build-flags coverage lane."""
import os, json

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "tests", "fparith_sweep")

# Diverse f64 operands: walking-bit mantissas, wide exponent range, both signs,
# powers of two (exact), and odd mantissas (full-width rounding).
INPUTS = [
    "1.0", "2.0", "0.5", "1.5", "1.25", "1.3333333333333333",
    "1.0000000000000002", "1.9999999999999998", "3.141592653589793",
    "2.718281828459045", "1e-300", "1e-30", "1e30", "1e300",
    "-1.5", "-7.0", "-1e15", "123456789.123456789", "0.1", "0.7",
    "9007199254740993.0", "6.103515625e-05", "-0.0", "65536.5",
]
OPS = ["fadd", "fsub", "fmul", "fdiv"]


def main():
    os.makedirs(OUT, exist_ok=True)
    L = ["# GENERATED FP-arith input sweep (run on the +VEN_FP_PIPE feature build)",
         "    .text", "    .globl _start", "_start:", "    finit"]
    consts = []
    idx = 0

    def k(v):
        nonlocal idx
        idx += 1
        nm = f"c{idx}"
        consts.append((nm, v))
        return nm

    # pair each input with a rotated partner so every op sees many distinct (a,b)
    n = len(INPUTS)
    for op in OPS:
        for i in range(n):
            a = INPUTS[i]
            b = INPUTS[(i * 7 + 3) % n]   # decorrelated partner
            na, nb = k(a), k(b)
            # st0 = a op b : load b then a so st0=a, st1=b; faddp-style via two-operand
            L += [f"    fldl {nb}", f"    fldl {na}", f"    {op} %st(1), %st(0)",
                  "    fstp %st(0)", "    fstp %st(0)"]
    L += ["    movl $1, %eax", "    xorl %ebx, %ebx", "    int $0x80"]
    L.append("    .data")
    L.append("    .align 8")
    for nm, val in consts:
        L.append(f"{nm}: .double {val}")
    open(os.path.join(OUT, "fparith_sweep.s"), "w").write("\n".join(L) + "\n")
    json.dump({"name": "fparith_sweep", "src": "fparith_sweep/fparith_sweep.s",
               "x87": True, "load_addr": "0x08048000", "entry": "0x08048000",
               "max_insn": len(L) + 40},
              open(os.path.join(OUT, "manifest.json"), "w"), indent=2)
    print(f"fparith_sweep: {len(OPS) * n} FP-arith evals over {n} diverse operands")


if __name__ == "__main__":
    main()
