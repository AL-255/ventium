#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""BCD value sweep (verif/cov/opgen/tests/bcd_sweep) — FBLD (80-bit packed BCD ->
extended) + FBSTP (-> packed BCD) over many BCD operands so the ITERATIVE BCD
engine (ven_bcd / ven_bcd_to_fp, gated +VEN_BCD_ITER) toggles its 18-digit
datapath. Same idea as gen_transc_sweep: a feature-gated iterative engine the
flags lane instantiates but barely exercises. Run against the cov-feat build."""
import os, json
HERE = os.path.dirname(os.path.abspath(__file__)); OUT = os.path.join(HERE, "tests", "bcd_sweep")
# 80-bit packed BCD: 9 bytes (18 digits) little-endian + 1 sign byte (0x00/0x80).
def bcd(digits, neg=False):
    d = (digits + "0"*18)[:18]
    by = [int(d[16-2*i:18-2*i], 16) for i in range(9)]
    return by + [0x80 if neg else 0x00]
VALS = [("0"*18, False), ("9"*18, False), ("9"*18, True), ("123456789012345678", False),
        ("000000000000000001", False), ("555555555555555555", False), ("100000000000000000", False),
        ("012345678901234567", True), ("999999999999999999", False), ("808080808080808080", False),
        ("010101010101010101", False), ("271828182845904523", False), ("314159265358979323", True)]
def main():
    os.makedirs(OUT, exist_ok=True)
    L = ["# GENERATED BCD value sweep (FBLD/FBSTP over diverse 80-bit packed BCD)",
         "    .text", "    .globl _start", "_start:", "    finit"]
    consts = []
    for i, (d, neg) in enumerate(VALS):
        consts.append((f"v{i}", bcd(d, neg)))
        L += [f"    fbld v{i}", "    fbstp tmp", "    fldl one", "    fldl one", "    faddp", "    fstp %st(0)"]
    L += ["    movl $1, %eax", "    xorl %ebx, %ebx", "    int $0x80",
          "    .data", "    .align 16", "one: .double 1.0", "tmp: .space 16"]
    for nm, by in consts:
        L.append(f"{nm}: .byte " + ",".join(f"0x{b:02x}" for b in by))
    open(os.path.join(OUT, "bcd_sweep.s"), "w").write("\n".join(L) + "\n")
    json.dump({"name": "bcd_sweep", "src": "bcd_sweep/bcd_sweep.s", "x87": True,
               "load_addr": "0x08048000", "entry": "0x08048000", "max_insn": len(L) + 30},
              open(os.path.join(OUT, "manifest.json"), "w"), indent=2)
    print(f"bcd_sweep: {len(VALS)} FBLD/FBSTP BCD values")
if __name__ == "__main__": main()
