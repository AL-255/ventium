#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# ============================================================================
# Radix-4 SRT SQUARE ROOT — golden reference model (prototype for the unified
# fpu_srt_div sqrt mode that SHARES the divide's carry-save recurrence + PLA).
#
# Unification with the divide (srt_model.py): the sqrt recurrence
#     w_j = 4*w_{j-1} - r_j*(2*R_{j-1} + r_j*4^-j)
# scaled by P = w/2 becomes
#     P_j = 4*P_{j-1} - r_j*(R_{j-1} + r_j*4^-j/2)
# i.e. the divide recurrence P_j = 4*(P_{j-1} - r*D) with divisor D = R + small
# correction. So the SAME radix-4 PLA (indexed by truncated P and column
# floor(16*R), R in [1,2)) selects the digit. R is the on-the-fly partial root.
#
# This file is HIGH-PRECISION (Fraction) to validate the ALGORITHM (digit
# selection + rounding) bit-exact vs IEEE before adding carry-save/truncation
# and porting to RTL.
# ============================================================================
import struct, math, sys
from fractions import Fraction
sys.path.insert(0, __import__("os").path.dirname(__file__))
from srt_model import pla   # reuse the EXACT divide ladder PLA

from srt_model import _enc, _fld, M, W, FRACW   # reuse the EXACT divide datapath fmt
NSTEP = 36                  # 2 root bits/step -> 72 fractional root bits (>= 64+guard)

def first_digit(P):
    """Special first root digit (R_0=1, divisor exactly 2.0 = PLA column edge)."""
    if P >= -7:  return 0          # X >= ~0.78
    if P >= -19: return -1         # X in [~0.407,0.78)
    return -2

def srt_sqrt_core(X):
    """X: Fraction radicand in [1/4,1). sqrt(X) in [1/2,1) is within the radix-4 SRT
    range [1/3,5/3] (R_0=1, digits {-2..2}*4^-j). CARRY-SAVE form == RTL fpu_srt_div
    sqrt mode: shares the divide's S^C^T+majority adder, <<2 shift, ladder PLA, and
    the _enc/_fld 8int.72frac ones-complement word. Returns (root_int,SH,rem_sign)."""
    twoR = Fraction(2)                     # 2R, on-the-fly (R_0=1)
    u = int(abs(4 * (X - 1)) * (1 << FRACW))
    S = ((~u) + 1) & M; C = 0              # initial remainder = 4*(X-1) (NEGATIVE) in
                                           # TWO's-complement (ones-comp -0 would mis-sign)
    for j in range(1, NSTEP+1):
        P = ((_fld(C) + _fld(S) + 64) % 128) - 64        # truncated 4int.3frac index
        if j == 1:
            r = first_digit(P)
        else:
            D = min(31, max(16, math.floor(16 * float(twoR))))   # column from divisor 2R
            r = pla(P, D, False)                                 # SHARED divide PLA
        F = twoR + Fraction(r) * Fraction(1, 4**j)               # divisor for this digit
        if   r > 0: T = (~_enc(Fraction(r)  * F)) & M; cf = True  # subtract: ones-comp +1
        elif r < 0: T =   _enc(Fraction(-r) * F);      cf = False # add
        else:       T = 0;                             cf = False
        s = S ^ C ^ T; carry = (((S & C) | (S & T) | (C & T)) << 1) & M
        if cf: carry |= 1
        S = (s << 2) & M; C = (carry << 2) & M                   # radix-4 shift (== divide)
        twoR = twoR + Fraction(2) * Fraction(r) * Fraction(1, 4**j)   # on-the-fly 2R
    v = (C + S) & M
    rem_sign = -1 if (v >> (W-1)) else (1 if v else 0)
    SH = 2 * NSTEP
    root_int = int((twoR / 2) * (1 << SH))           # R = twoR/2, exact on-the-fly root
    return root_int, SH, rem_sign

def _round_fx80(root_int, SH, rem_sign, e_half):
    if root_int == 0: return 0
    msb = root_int.bit_length() - 1; extra = msb - 63
    keep = root_int >> extra; remv = root_int & ((1 << extra)-1); half = 1 << (extra-1)
    if   remv > half: up = True
    elif remv < half: up = False
    else:             up = (rem_sign > 0) or (rem_sign == 0 and (keep & 1))
    if up: keep += 1
    e = (msb - SH) + e_half
    if keep >> 64: keep >>= 1; e += 1
    return (((e + 16383) & 0x7fff) << 64) | (keep & ((1 << 64)-1))

def decompose(x):
    b = struct.unpack('<Q', struct.pack('<d', x))[0]
    f = b & ((1 << 52)-1); e = (b >> 52) & 0x7ff
    return Fraction((1 << 52) | f, 1 << 52), e - 1023

def fsqrt_fx80(x):
    """x: positive Python float. Returns floatx80 sqrt bits (no sign)."""
    sig, e = decompose(x)                  # value = sig * 2^e, sig in [1,2)
    # normalize to value = X * 4^k, X in [1/4,1) -> sqrt = sqrt(X)*2^k, sqrt(X) in [1/2,1).
    if e & 1: X = sig / 2;  k = (e + 1) // 2        # odd:  X=sig/2  in [1/2,1)
    else:     X = sig / 4;  k = e // 2 + 1          # even: X=sig/4  in [1/4,1/2)
    root_int, SH, rs = srt_sqrt_core(X)
    # R in [1/2,1) -> root_int MSB at bit SH-1; _round_fx80's (msb-SH) gives k-1, and
    # keep's MSB lands at bit63 (= the 1.xxx significand of sqrt(X)*2). e_half = k.
    return _round_fx80(root_int, SH, rs, k)

def ieee_sqrt_fx80(x):
    """Correctly-rounded floatx80 of sqrt(x), exact (high precision)."""
    sig, e = decompose(x)
    val = sig * (Fraction(2) ** e)
    # exact sqrt to >80 bits via integer isqrt on a scaled value
    scale = 2 * (e if e >= 0 else 0) + 200
    num = val.numerator << (scale*2); den = val.denominator
    root = math.isqrt(num // den)          # floor(sqrt(val) * 2^scale)
    # normalize root to 1.xxx and round to 64-bit significand
    rv = Fraction(root, 1 << scale)
    ee = 0
    while rv >= 2: rv /= 2; ee += 1
    while rv < 1:  rv *= 2; ee -= 1
    sc = rv * (1 << 63); fl = sc.numerator // sc.denominator; rr = sc - fl
    # sticky: the true sqrt has more bits than `root` captured? root is floor, so
    # inexact unless val is a perfect square. Use a fine remainder for round-nearest.
    exact = (root*root == (num//den)) and (num % den == 0)
    if rr > Fraction(1,2) or (rr == Fraction(1,2) and (fl & 1)): fl += 1
    if fl >= (1<<64): fl >>= 1; ee += 1
    return (((ee+16383)&0x7fff)<<64)|(fl&((1<<64)-1))

if __name__ == "__main__":
    import random
    random.seed(7)
    tests = [2.0, 4.0, 0.5, 1.0, 3.0, 1.5, 9.0, 16.0, 2.5, 100.0, 0.25]
    bad = 0
    for x in tests:
        g = fsqrt_fx80(x); r = ieee_sqrt_fx80(x)
        ok = (g == r)
        if not ok: bad += 1
        print(f"sqrt({x:<8}) model=0x{g:020X} ieee=0x{r:020X} {'ok' if ok else 'DIFF'}")
    n = 5000; nb = 0
    for _ in range(n):
        x = random.uniform(1e-3, 1e3)
        if fsqrt_fx80(x) != ieee_sqrt_fx80(x): nb += 1
    print(f"random corpus: {n-nb}/{n} bit-exact")
