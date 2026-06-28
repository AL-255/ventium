#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Generate a transcendental INPUT SWEEP (verif/cov/opgen/tests/transc_sweep) —
each x87 transcendental run over many operands (0, fractions of pi, >1, large,
negative, near-range-reduction-boundary) so the in-RTL engine's range reduction +
iteration/CORDIC paths are exercised, not just one input. Built for the
+VEN_TRANSCENDENTAL feature build; run by run-transc.sh's coverage pass."""
import os, json

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "tests", "transc_sweep")

# (mnemonic, needs a 2nd operand on the stack?, list of input expressions in C)
# inputs are loaded as f64 constants via the data section.
INPUTS = ["0.0", "0.5", "0.7853981633974483", "1.5707963267948966",
          "3.141592653589793", "6.283185307179586", "-2.3", "100.25",
          "1e-9", "1e9", "0.999999", "12345.678"]
# NOTE: fxtract excluded — it HALTs even in the feature build (cataloged gap),
# and would stop the sweep before the later ops run.
UNARY = ["fsin", "fcos", "fptan", "f2xm1", "frndint", "fsqrt"]
BINARY = ["fyl2x", "fpatan", "fyl2xp1"]   # need st1 (y) and st0 (x)


def main():
    os.makedirs(OUT, exist_ok=True)
    L = ["# GENERATED transcendental input sweep (run on the +VEN_TRANSCENDENTAL build)",
         "    .text", "    .globl _start", "_start:", "    finit"]
    idx = 0

    def load(val):
        nonlocal idx
        idx += 1
        return f"in{idx}", val

    consts = []
    for mn in UNARY:
        for v in INPUTS:
            nm, val = load(v)
            consts.append((nm, val))
            L += [f"    fldl {nm}", f"    {mn}", "    fstp %st(0)"]   # load, op, discard
    for mn in BINARY:
        for v in INPUTS:
            nm, val = load(v)
            consts.append((nm, val))
            # y=1.0 in st1, x=v in st0
            L += ["    fld1", f"    fldl {nm}", f"    {mn}", "    fstp %st(0)"]
    # FPREM / FPREM1 (st0 mod st1) — iterative; sweep dividend/divisor pairs that
    # need multiple reduction steps (large quotient) + small ones.
    for mn in ("fprem", "fprem1"):
        for dvd, dvs in [("100.25", "3.0"), ("1e9", "7.0"), ("3.5", "2.0"),
                         ("12345.678", "1.1"), ("-2.3", "0.7"), ("1e18", "3.0")]:
            d1, _ = load(dvd); consts.append((d1, dvd))
            d2, _ = load(dvs); consts.append((d2, dvs))
            L += [f"    fldl {d2}", f"    fldl {d1}", f"    {mn}",
                  "    fstp %st(0)", "    fstp %st(0)"]
    L += ["    movl $1, %eax", "    xorl %ebx, %ebx", "    int $0x80"]
    # data section
    L.append("    .data")
    L.append("    .align 8")
    for nm, val in consts:
        L.append(f"{nm}: .double {val}")
    open(os.path.join(OUT, "transc_sweep.s"), "w").write("\n".join(L) + "\n")
    json.dump({"name": "transc_sweep", "src": "transc_sweep/transc_sweep.s",
               "x87": True, "load_addr": "0x08048000", "entry": "0x08048000",
               "max_insn": len(L) + 20},
              open(os.path.join(OUT, "manifest.json"), "w"), indent=2)
    print(f"transc_sweep: {len(UNARY)*len(INPUTS) + len(BINARY)*len(INPUTS)} transcendental evals")


if __name__ == "__main__":
    main()
