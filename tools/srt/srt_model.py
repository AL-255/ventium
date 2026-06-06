#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# ============================================================================
# Pentium radix-4 SRT divider — single-source golden reference model.
#
# Faithful Coe-Tang datapath (Edelman 1997, "The Mathematics of the Pentium
# Division Bug"; Ken Shirriff, righto.com 2024 — the reverse-engineered PLA).
# Ones-complement carry-save partial remainder, 4-integer-bit truncated index,
# the delayed +1 correction, and a remainder-sign-aware final rounding.
#
# This module IS the oracle for the SystemVerilog port (fpu_x87_pkg::fx_srt_div).
# Validated: correct PLA == correctly-rounded floatx80 (== QEMU); buggy PLA
# reproduces the documented FDIV flaw from first principles (no operand is
# special-cased). See tools/srt/README.md.
# ============================================================================
import struct, math
from fractions import Fraction

# parameters mirrored exactly by the RTL
IDX_IW, REG_IW, FRACW, NSTEP = 4, 8, 72, 36
W, M = REG_IW + FRACW, (1 << (REG_IW + FRACW)) - 1
BAD_DP = {18, 21, 24, 27, 30}                 # D in {17,20,23,26,29}/16

def _lookup_raw(P, Dp):                        # Edelman's MATLAB table generator
    qq  = (P >= math.floor(-8*Dp/6)-1) + (P >= math.ceil(-5*Dp/6))
    qq += (P >= math.floor(-4*Dp/6)-1) + (P >= math.ceil(-2*Dp/6))
    qq += (P >= math.floor(  -Dp/6)-1) + (P >= math.ceil(   Dp/6))
    qq += (P >= math.floor( 2*Dp/6)-1) + (P >= math.ceil( 4*Dp/6))
    qq += (P >= math.floor( 5*Dp/6)-1) + (P >= math.ceil( 8*Dp/6))
    return (qq - 5) / 2
def _resolve(qh):                              # overlap -> larger-magnitude digit
    if qh == int(qh): return int(qh)
    return math.ceil(qh) if qh > 0 else math.floor(qh)
def _thresholds(D):                            # lower-bound ladder thresholds (1/8 units)
    Dp = D + 1; T = {}
    for q in (2, 1, 0, -1):
        T[q] = next(P for P in range(-64, 64)
                    if min(2, max(-2, _resolve(_lookup_raw(P, Dp)))) >= q)
    return T
_THR = {D: _thresholds(D) for D in range(16, 32)}
def pla(P, D, buggy):                          # ladder PLA — EXACTLY mirrors fx_srt_pla
    Dp = D + 1
    if buggy and Dp in BAD_DP and P == 4*Dp//3 - 1:
        return 0                               # missing +2 cell -> 0 (the flaw)
    T = _THR[D]                                 # clamp to {-2..2}: any P>=T2 -> +2 (no +-2.5)
    if   P >= T[2]:  return 2
    elif P >= T[1]:  return 1
    elif P >= T[0]:  return 0
    elif P >= T[-1]: return -1
    else:            return -2

def _enc(fr):
    neg = fr < 0; iv = int(abs(fr) * (1 << FRACW)); u = iv & M
    return (~u) & M if neg else u
def _fld(u):                                   # signed 4int.3frac index field
    f = (u >> (FRACW - 3)) & 0x7F
    return f - 128 if f >> 6 else f

def srt_core(p_sig, d_sig, buggy):
    """p_sig,d_sig: Fraction significands in [1,2). Returns (qacc, SH, rem_sign)."""
    D = math.floor(16 * float(d_sig)); S = _enc(p_sig); C = 0; digits = []
    for k in range(NSTEP):
        P = ((_fld(C) + _fld(S) + 64) % 128) - 64
        q = pla(P, D, buggy); digits.append(q)
        if   q > 0: T = (~_enc(Fraction(q)   * d_sig)) & M; cf = True
        elif q < 0: T =   _enc(Fraction(-q)  * d_sig);      cf = False
        else:       T = 0;                                  cf = False
        s = S ^ C ^ T; carry = (((S & C) | (S & T) | (C & T)) << 1) & M
        if cf: carry |= 1
        S = (s << 2) & M; C = (carry << 2) & M
    v = (C + S) & M                            # remainder value (mod 2^W)
    rem_sign = -1 if (v >> (W - 1)) else (1 if v else 0)
    SH = 2 * (NSTEP - 1)
    qacc = sum(q << (SH - 2*k) for k, q in enumerate(digits))
    return qacc, SH, rem_sign

# ---- floatx80 helpers -------------------------------------------------------
def decompose(x):
    b = struct.unpack('<Q', struct.pack('<d', x))[0]
    f = b & ((1 << 52)-1); e = (b >> 52) & 0x7ff; s = b >> 63
    return s, Fraction((1 << 52) | f, 1 << 52), e - 1023
def double_to_fx80(x):
    s, sig, e = decompose(x); fl = int(sig * (1 << 63))
    return (s << 79) | (((e + 16383) & 0x7fff) << 64) | (fl & ((1 << 64)-1))
def _round_fx80(sign, qacc, SH, rem_sign, e_adj):
    if qacc == 0: return sign << 79
    msb = qacc.bit_length() - 1; extra = msb - 63
    keep = qacc >> extra; remv = qacc & ((1 << extra)-1); half = 1 << (extra-1)
    if   remv > half: up = True
    elif remv < half: up = False
    else:             up = (rem_sign > 0) or (rem_sign == 0 and (keep & 1))
    if up: keep += 1
    e = (msb - SH) + e_adj
    if keep >> 64: keep >>= 1; e += 1
    return (sign << 79) | (((e + 16383) & 0x7fff) << 64) | (keep & ((1 << 64)-1))

def fdiv_fx80(num, den, buggy):
    """num,den: Python floats (doubles). Returns floatx80 quotient bits."""
    sa, ps, pe = decompose(num); sb, ds, de = decompose(den)
    if den == 0.0:  # x/0 -> signed Inf (matches fx_srt_div guard)
        return ((sa ^ sb) << 79) | (0x7fff << 64) | (1 << 63)
    if num == 0.0:
        return (sa ^ sb) << 79
    qacc, SH, rs = srt_core(ps, ds, buggy)
    return _round_fx80(sa ^ sb, qacc, SH, rs, pe - de)
def fx80_to_double(fx):
    sign = fx >> 79; exp = (fx >> 64) & 0x7fff; man = fx & ((1 << 64)-1)
    v = Fraction(man, 1 << 63) * (Fraction(2) ** (exp - 16383))
    return struct.unpack('<Q', struct.pack('<d', float((-1 if sign else 1) * v)))[0]

def emit_sv_pla():
    """Emit the per-column SystemVerilog case block for fx_srt_pla (D=16..31)."""
    def s(x): return f"7'sd{x}" if x >= 0 else f"-7'sd{-x}"
    for D in range(16, 32):
        T = _THR[D]; Dp = D + 1
        bad = 1 if Dp in BAD_DP else 0
        pb  = (4*Dp//3 - 1) if Dp in BAD_DP else 0
        print(f"        4'd{D-16:<2}: begin t2= {s(T[2]):>6}; t1= {s(T[1]):>5}; "
              f"t0= {s(T[0]):>6}; tm1= {s(T[-1]):>6}; bad=1'b{bad}; pb= {s(pb):>5}; end")

if __name__ == "__main__":
    import sys, random
    if len(sys.argv) > 1 and sys.argv[1] == "pla":
        emit_sv_pla(); sys.exit(0)
    CORR, FLAW = 0x3FF557541C7C6B43, 0x3FF556FEC7254ED1
    fc = fdiv_fx80(4195835.0, 3145727.0, False)
    fb = fdiv_fx80(4195835.0, 3145727.0, True)
    print(f"canonical correct fx80=0x{fc:020X} dbl=0x{fx80_to_double(fc):016X} ok={fx80_to_double(fc)==CORR}")
    print(f"canonical flawed  fx80=0x{fb:020X} dbl=0x{fx80_to_double(fb):016X} ok={fx80_to_double(fb)==FLAW}")
    random.seed(99); bad = 0
    for _ in range(10000):
        a = random.randint(1<<20,(1<<24)-1); b = random.randint(1<<20,(1<<24)-1)
        ref = double_to_fx80(0.0)  # placeholder
        # exact correctly-rounded floatx80 of a/b
        v = Fraction(a, b); e = 0
        while v >= 2: v /= 2; e += 1
        while v < 1:  v *= 2; e -= 1
        sc = v*(1<<63); fl = sc.numerator//sc.denominator; r = sc-fl
        if r > Fraction(1,2) or (r == Fraction(1,2) and (fl & 1)): fl += 1
        if fl >= (1<<64): fl >>= 1; e += 1
        ref = (((e+16383)&0x7fff)<<64)|(fl&((1<<64)-1))
        if fdiv_fx80(float(a), float(b), False) != ref: bad += 1
    print(f"correct-PLA floatx80 corpus: {10000-bad}/10000 exact")
