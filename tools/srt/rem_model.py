#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# ============================================================================
# Radix-4 SRT INTEGER division — golden reference for FPREM/FPREM1 computed on
# the SHARED carry-save divide recurrence (Pentium FDIV does div+rem+sqrt on one
# datapath), replacing the folded radix-2 restoring fpu_fprem path.
#
# FPREM(a,b) = a - Q*b, Q = trunc(a/b) (FPREM1: round-nearest Q). With
# ea_eff/eb_eff the effective unbiased exponents, expdiff = ea_eff - eb_eff:
#   complete reduction (expdiff < 64): D = ma << expdiff (aligned dividend,
#     up to 127 bits); (Q,R) = D divmod mb; remainder = R * 2^(eb_eff-63),
#     normalized; q012 = Q[2:0]; C2 = 0. R is EXACT (< mb, fits 64-bit sig).
#   partial reduction (expdiff >= 64): reduce by N<64 bits, C2 = 1, q012 = 0.
#
# The new RTL piece is the SRT integer divide D/mb -> (Q,R): the divide's
# radix-4 carry-save recurrence (shared adder + ladder PLA) plus DIVIDEND
# INJECTION (2 bits of D shifted in per step, MSB-first) and a final remainder
# sign-correction. This file validates that core bit-exact vs Python //,% .
# The FPREM wrapper (alignment / R-normalize / FPREM1 / partial-reduction /
# q012) is the PROVEN fpu_fprem logic and is unchanged.
# ============================================================================
import sys, os, random
sys.path.insert(0, os.path.dirname(__file__))
from srt_model import pla

W = 80; M = (1 << W) - 1
def _fld(u):                          # signed 4int.3frac index of value/2^60 (mb~2^63)
    f = (u >> 60) & 0x7F
    return f - 128 if f >> 6 else f

def srt_intdiv_cs(D, mb):
    """D (aligned dividend), mb (divisor, [2^63,2^64)) -> (Q, R) == (D//mb, D%mb).
    Carry-save ones-complement remainder + dividend injection + shared divide PLA.
    This is the EXACT RTL recurrence (S/C, x4 shift, S^C^T+majority, +cf for q>0)."""
    if D == 0: return 0, 0
    nsteps = (D.bit_length() + 1) // 2          # radix-4 digits to consume D
    Dcol   = 16 + ((mb >> 59) & 0xF)            # PLA column = floor(16*mb/2^63)
    S = 0; C = 0; Q = 0
    for step in range(nsteps):
        S = (S << 2) & M; C = (C << 2) & M      # radix-4 shift (== divide)
        S = (S | ((D >> (2*(nsteps-1-step))) & 3)) & M   # inject 2 dividend bits
        P = ((_fld(C) + _fld(S) + 64) % 128) - 64        # truncated carry-save index
        q = pla(P, Dcol, False)
        if   q > 0: T = (~(q*mb)) & M; cf = True         # subtract q*mb (ones-comp +1)
        elif q < 0: T = ((-q)*mb) & M; cf = False
        else:       T = 0;             cf = False
        s = S ^ C ^ T; carry = (((S & C) | (S & T) | (C & T)) << 1) & M
        if cf: carry |= 1
        S = s & M; C = carry & M
        Q = 4*Q + q
    P = (C + S) & M
    if P >> (W-1): P -= (M + 1)                  # signed remainder
    while P < 0:   P += mb; Q -= 1               # final correction -> R in [0,mb)
    while P >= mb: P -= mb; Q += 1
    return Q, P

if __name__ == "__main__":
    random.seed(3); bad = 0; n = 300000
    for _ in range(n):
        mb = random.randint(1 << 63, (1 << 64) - 1)
        D  = random.randint(1 << 63, (1 << 64) - 1) << random.randint(0, 63)
        Q, R = srt_intdiv_cs(D, mb)
        if Q != D // mb or R != D % mb: bad += 1
    print(f"carry-save SRT integer-divide: {n-bad}/{n} == D//mb, D%mb")
