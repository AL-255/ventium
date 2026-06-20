# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# tx_unifdiv -- exercise the OVERHAULED unified FDIV/FSQRT/FPREM carry-save
# datapath (rtl/fpu/fpu_srt_div.sv under VEN_SRT_ITER; the combinational
# fx_div/fx_sqrt/fx_prem otherwise) over varied operands: exact + inexact
# quotients, perfect + non-perfect square roots, small + large remainders.
# All deterministic + bit-exact vs QEMU -> a plain x87 test (passes make verify).
    .text
    .globl _start
_start:
    finit
    # ---- FDIV: exact, inexact, by powers of two, large/small ----
    flds  c_10;  flds  c_4;   fdivp %st, %st(1)   # 4/10 = 0.4 (inexact)
    flds  c_100; flds  c_4;   fdivp %st, %st(1)   # 4/100
    fld1;        flds  c_3;   fdivp %st, %st(1)   # 3/1 = 3 (exact)
    flds  c_8;   flds  c_2;   fdiv  %st(1), %st   # 2/8 (pow2)
    fxch;        fdivr %st(1), %st                # reverse divide
    finit
    # ---- FSQRT: perfect + non-perfect + <1 + denormal-ish ----
    flds  c_4;   fsqrt                            # 2.0 (exact)
    flds  c_2;   fsqrt                            # 1.414... (inexact)
    flds  c_p25; fsqrt                            # 0.5
    flds  c_1e9; fsqrt                            # large
    finit
    # ---- FPREM / FPREM1: small + large ratio, near-exact ----
    flds  c_10;  flds  c_3;   fprem               # 10 % 3 -> 1
    fstp  %st(0)
    flds  c_100; flds  c_7;   fprem1              # IEEE remainder
    fstp  %st(0)
    flds  c_2;   flds  c_1e9; fprem               # huge ratio (multi-step)
    # ---- FABS / FCHS (simple sign ops) ----
    flds  c_10;  fabs;  fchs;  fstp %st(0)
    finit
    movl  $1, %eax
    xorl  %ebx, %ebx
    int   $0x80
    .data
    .align 4
c_2:   .float 2.0
c_3:   .float 3.0
c_4:   .float 4.0
c_7:   .float 7.0
c_8:   .float 8.0
c_10:  .float 10.0
c_100: .float 100.0
c_p25: .float 0.25
c_1e9: .float 1000000000.0
