#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# confirm_pc24.py — confirm the PC=24 (single-precision) board-F5 divergence
# hypothesis from a captured Ventium XoverArch (.arch) WITHOUT needing qemu.
#
# Logic: Quake sets x87 PC=24-bit single precision. A single-precision floatx80
# value has a 24-bit significand -> the low 40 bits of the 64-bit significand
# (bits 39..0) MUST be zero. The board build (VEN_FP_PC_RELAX) ignores PC and
# computes 64-bit extended, so its register significands carry NONZERO low-40
# bits. If ST0 / the recent stack regs show populated bits below bit 40 while
# FCTRL says PC=00, that IS the extended-precision residue that diverges from a
# real PC=24 machine (qemu) -> the accumulation that yields the wrong fist.
#
# Usage: confirm_pc24.py <prefix.arch>
import sys, struct
from fractions import Fraction

d = open(sys.argv[1], 'rb').read()
assert d[:7] == b'VENXOVR', "bad magic"
fctrl, fstat = struct.unpack_from('<HH', d, 188)
ftag = d[192]; ftop = d[193]
pc = (fctrl >> 8) & 3; rc = (fctrl >> 10) & 3
PCNAME = {0: "24-bit SINGLE", 1: "reserved", 2: "53-bit DOUBLE", 3: "64-bit EXTENDED"}
print("FCTRL=%04x  PC=%d (%s)  RC=%d  ftop=%d  ftag=%02x" % (fctrl, pc, PCNAME[pc], rc, ftop, ftag))
print("-" * 72)

def fpr(i):
    lo = struct.unpack_from('<Q', d, 196 + i * 8)[0]
    hi = struct.unpack_from('<H', d, 260 + i * 2)[0]
    return hi, lo

# 24-bit single keeps significand bits 63..40 (24 bits incl. integer bit) -> low 40 must be 0.
# 53-bit double keeps 63..11 -> low 11 must be 0.
low_mask = (1 << 40) - 1 if pc == 0 else ((1 << 11) - 1 if pc == 2 else 0)
flagged = 0
for st in range(8):
    i = (ftop + st) & 7
    tagbits = (ftag >> (i * 1)) & 1   # raw 8-bit tag: 1 bit/reg (0=empty here per RTL ftag)
    hi, lo = fpr(i)
    sign = hi >> 15; e = hi & 0x7fff
    note = ""
    if e not in (0, 0x7fff):
        v = Fraction(lo) * (Fraction(2) ** (e - 16383 - 63))
        v = -v if sign else v
        residue = lo & low_mask
        if residue:
            note = "  <-- LOW-%d BITS SET (%010x) = extended-precision residue vs PC=%d!" % (
                40 if pc == 0 else 11, residue, pc)
            flagged += 1
        print("ST%d fpr[%d] = %04x%016x  val=%.10g%s" % (st, i, hi, lo, float(v), note))
    else:
        print("ST%d fpr[%d] = %04x%016x  (zero/inf/nan/empty)" % (st, i, hi, lo))

print("-" * 72)
if pc == 3:
    print("PC=64-bit extended: no precision divergence expected (this capture isn't the PC=24 point).")
elif flagged:
    print("CONFIRMED: %d register(s) carry sub-precision residue while FCTRL=PC=%d." % (flagged, pc))
    print("=> Ventium (VEN_FP_PC_RELAX, 64-bit) DIVERGES from a real PC=%d machine (qemu)." % pc)
    print("=> Root cause = f_eval/fx_round_pack ignore PC. Fix = round mantissa to %d bits." %
          (24 if pc == 0 else 53))
else:
    print("No sub-precision residue found in the live regs — PC divergence NOT evidenced here;")
    print("re-capture at an arith PC, or the divergence is elsewhere (need qemu ST0 compare).")
