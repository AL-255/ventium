# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium test: tx_fprem -- x87 FPREM (D9 F8), exact partial remainder.
# =============================================================================
# Freestanding 32-bit i386. AT&T / GNU as. Each case: load divisor then dividend
# (st0=a, st1=b), FPREM (st0 = a - trunc(a/b)*b, exact), pop result + divisor.
# The diff only has to MATCH qemu's floatx80 remainder + the C0/C3/C1/C2 codes;
# we don't hand-predict the rounded value. Default control word (round-near,
# 64-bit precision). Deterministic; exits via int 0x80.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- full reduction, exact integer remainders (expdiff < 64) -------------
    flds f_3;   flds f_5;    fprem;  fstp %st(0); fstp %st(0)   # 5 mod 3  = 2  (q=1)
    flds f_2;   flds f_7;    fprem;  fstp %st(0); fstp %st(0)   # 7 mod 2  = 1  (q=3 -> C0=0,C3=1,C1=1)
    flds f_3;   flds f_10;   fprem;  fstp %st(0); fstp %st(0)   # 10 mod 3 = 1  (q=3)
    flds f_1;   flds f_1;    fprem;  fstp %st(0); fstp %st(0)   # 1 mod 1  = 0  (q=1)
    flds f_7;   flds f_100;  fprem;  fstp %st(0); fstp %st(0)   # 100 mod 7= 2  (q=14 -> C0=1,C3=1,C1=0)
    flds f_3;   flds f_1000; fprem;  fstp %st(0); fstp %st(0)   # 1000 mod 3=1  (q=333)

    # ---- |a| < |b| : remainder = a, q = 0 ------------------------------------
    flds f_5;   flds f_2;    fprem;  fstp %st(0); fstp %st(0)   # 2 mod 5  = 2  (q=0)
    flds f_3;   flds f_0;    fprem;  fstp %st(0); fstp %st(0)   # 0 mod 3  = 0

    # ---- signed dividend/divisor (remainder takes ST0's sign) ----------------
    flds f_2;   flds f_n7;   fprem;  fstp %st(0); fstp %st(0)   # -7 mod 2  = -1
    flds f_n2;  flds f_7;    fprem;  fstp %st(0); fstp %st(0)   #  7 mod -2 =  1

    # ---- fractional remainders (double precision operands) -------------------
    fldl d_2_0; fldl d_5_5;  fprem;  fstp %st(0); fstp %st(0)   # 5.5 mod 2.0 = 1.5
    fldl d_1_0; fldl d_pi;   fprem;  fstp %st(0); fstp %st(0)   # pi mod 1.0  = 0.14159...
    fldl d_2_1; fldl d_7_3;  fprem;  fstp %st(0); fstp %st(0)   # 7.3 mod 2.1 = 1.0

    # ---- larger expdiff (still < 64) -----------------------------------------
    fldl d_3_0; fldl d_1e10; fprem;  fstp %st(0); fstp %st(0)   # 1e10 mod 3

    # ---- partial reduction (expdiff >= 64): C2=1, partial result -------------
    fldl d_3_0; fldl d_1e30; fprem;  fstp %st(0); fstp %st(0)   # huge ratio -> partial (C2=1)

    # ---- clean exit ----------------------------------------------------------
    movl $1, %eax
    xorl %ebx, %ebx
    int  $0x80

    .data
    .align 8
f_0:    .float  0.0
f_1:    .float  1.0
f_2:    .float  2.0
f_3:    .float  3.0
f_5:    .float  5.0
f_7:    .float  7.0
f_10:   .float  10.0
f_100:  .float  100.0
f_1000: .float  1000.0
f_n2:   .float  -2.0
f_n7:   .float  -7.0
d_1_0:  .double 1.0
d_2_0:  .double 2.0
d_2_1:  .double 2.1
d_3_0:  .double 3.0
d_5_5:  .double 5.5
d_7_3:  .double 7.3
d_pi:   .double 3.14159265358979
d_1e10: .double 1.0e10
d_1e30: .double 1.0e30
