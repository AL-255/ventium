# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium test: tx_fprem -- x87 FPREM (D9 F8) / FPREM1 (D9 F5), exact partial
# remainder (truncating quotient) and IEEE remainder (round-nearest quotient).
# =============================================================================
# Freestanding 32-bit i386. AT&T / GNU as. Each case: load divisor then dividend
# (st0=a, st1=b), FPREM/FPREM1 (st0 = a - Q*b, exact), pop result + divisor.
# The diff only has to MATCH qemu's floatx80 remainder + the C0/C3/C1/C2 codes;
# we don't hand-predict the rounded value. Default control word (round-near,
# 64-bit precision) except the explicit RC sweep. Deterministic; exits via
# int 0x80.
#
# Coverage: complete reduction, |a|<|b| (Q=0), signed operands, fractional
# operands, large exponent ratios, the C2=1 PARTIAL path (incl. the software
# re-execution idiom: re-run FPREM until C2 clears), quotient condition codes
# (C0/C3/C1 = Q2/Q1/Q0 -- q=0..7 for FPREM, the nearest quotient for FPREM1),
# zero/NaN/Inf operands (masked #IA -> QNaN indefinite), all four control-word
# rounding modes (the remainder is exact, so RC must not change the result),
# and back-to-back engine users (FPREM;FPREM / FPREM1;FPREM1 with no reload,
# FPREM->FDIV, FDIV->FPREM, FPREM1->FSQRT -- the iterative builds share one
# unified divide/remainder engine across these).
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

    # ---- FPREM1 (D9 F5): IEEE remainder, quotient to NEAREST ------------------
    flds f_3;   flds f_5;    fprem1; fstp %st(0); fstp %st(0)   # 5 mod 3:  Q=2, rem=-1
    flds f_2;   flds f_7;    fprem1; fstp %st(0); fstp %st(0)   # 7 mod 2:  3.5 ties-even Q=4, rem=-1
    flds f_3;   flds f_10;   fprem1; fstp %st(0); fstp %st(0)   # 10 mod 3: Q=3, rem=+1
    flds f_5;   flds f_22;   fprem1; fstp %st(0); fstp %st(0)   # 22 mod 5: Q=4, rem=+2
    flds f_5;   flds f_23;   fprem1; fstp %st(0); fstp %st(0)   # 23 mod 5: 4.6 -> Q=5, rem=-2
    fldl d_2_0; fldl d_5_5;  fprem1; fstp %st(0); fstp %st(0)   # 5.5 mod 2: 2.75 -> Q=3, rem=-0.5
    fldl d_3_0; fldl d_1e30; fprem1; fstp %st(0); fstp %st(0)   # huge ratio, FPREM1 form

    # ---- quotient condition codes: q low bits Q2Q1Q0 -> C0/C3/C1 --------------
    # FPREM (truncating): q=0 (2 mod 5), q=1 (5 mod 3), q=3 (7 mod 2) above; add
    # q=2,4,5,6,7 so every C0/C3/C1 combination is sampled.
    flds f_3;   flds f_8;    fprem;  fstp %st(0); fstp %st(0)   # 8 mod 3:  q=2, rem=2
    flds f_2;   flds f_9;    fprem;  fstp %st(0); fstp %st(0)   # 9 mod 2:  q=4, rem=1
    flds f_2;   flds f_11;   fprem;  fstp %st(0); fstp %st(0)   # 11 mod 2: q=5, rem=1
    flds f_2;   flds f_13;   fprem;  fstp %st(0); fstp %st(0)   # 13 mod 2: q=6, rem=1
    flds f_2;   flds f_15;   fprem;  fstp %st(0); fstp %st(0)   # 15 mod 2: q=7, rem=1
    # FPREM1 (nearest quotient): Q=2/3/4/5 above; add Q=0,1,6,7.
    flds f_4;   flds f_2;    fprem1; fstp %st(0); fstp %st(0)   # 2 mod 4:  Q=0, rem=2
    flds f_4;   flds f_5;    fprem1; fstp %st(0); fstp %st(0)   # 5 mod 4:  1.25 -> Q=1, rem=1
    flds f_4;   flds f_25;   fprem1; fstp %st(0); fstp %st(0)   # 25 mod 4: 6.25 -> Q=6, rem=1
    flds f_4;   flds f_27;   fprem1; fstp %st(0); fstp %st(0)   # 27 mod 4: 6.75 -> Q=7, rem=-1

    # ---- zero / NaN / Inf operands (masked #IA -> QNaN indefinite, IE) --------
    flds f_3;   flds f_0;    fprem;  fstp %st(0); fstp %st(0)   # 0 mod 3 = +0, q=0
    flds f_3;   flds f_n0;   fprem;  fstp %st(0); fstp %st(0)   # -0 mod 3 = -0 (dividend's sign)
    flds f_0;   flds f_3;    fprem;  fstp %st(0); fstp %st(0)   # 3 mod 0 -> #IA
    fnclex
    flds f_0;   flds f_3;    fprem1; fstp %st(0); fstp %st(0)   # 3 mod 0 via FPREM1 -> #IA
    fnclex
    flds f_3;   flds f_pinf; fprem;  fstp %st(0); fstp %st(0)   # +inf mod 3 -> #IA
    fnclex
    flds f_pinf; flds f_3;   fprem;  fstp %st(0); fstp %st(0)   # 3 mod +inf -> rem=3, q=0
    flds f_3;   flds f_qnan; fprem;  fstp %st(0); fstp %st(0)   # QNaN mod 3 -> #IA
    fnclex
    flds f_3;   flds f_qnan; fprem1; fstp %st(0); fstp %st(0)   # QNaN via FPREM1 -> #IA
    fnclex

    # ---- control-word RC sweep: the remainder is EXACT, so RC is unobservable -
    fldcw cw_dn
    flds f_3;   flds f_7;    fprem;  fstp %st(0); fstp %st(0)   # 7 mod 3 = 1 (q=2), RC=down
    flds f_3;   flds f_7;    fprem1; fstp %st(0); fstp %st(0)   # Q=2 rem=1, RC=down
    fldcw cw_up
    flds f_3;   flds f_7;    fprem;  fstp %st(0); fstp %st(0)   # RC=up
    flds f_3;   flds f_7;    fprem1; fstp %st(0); fstp %st(0)   # RC=up
    fldcw cw_tz
    flds f_3;   flds f_7;    fprem;  fstp %st(0); fstp %st(0)   # RC=tozero
    flds f_3;   flds f_7;    fprem1; fstp %st(0); fstp %st(0)   # RC=tozero
    fldcw cw_rne
    flds f_3;   flds f_7;    fprem;  fstp %st(0); fstp %st(0)   # RC=near (the default above)
    flds f_3;   flds f_7;    fprem1; fstp %st(0); fstp %st(0)   # RC=near

    # ---- partial-reduction re-execution idiom: re-run until C2=0 --------------
    # expdiff ~= 67: the first pass is partial (C2=1, ~36 engine clocks), the
    # second completes (~34 clocks) -- each pass stays well under the TB's idle
    # threshold, and the loop count still exceeds one.
    fldl d_3_0; fldl d_1e21
1:  fprem
    fnstsw %ax
    testb $0x04, %ah                    # C2 (FSW bit 10) = AH bit 2
    jnz 1b
    fstp %st(0); fstp %st(0)            # 1e21 mod 3, fully reduced
    fldl d_3_0; fldl d_1e21
2:  fprem1
    fnstsw fsw_tmp                      # m16 form: the status never enters a GPR
    testb $0x04, fsw_tmp+1              # C2 (FSW bit 10) = high-byte bit 2
    jnz 2b
    fstp %st(0); fstp %st(0)            # same ratio, FPREM1 form

    # ---- back-to-back remainder ops (no reload between the two) ---------------
    flds f_3;   flds f_100;  fprem;  fprem;  fstp %st(0); fstp %st(0)
        # 100 mod 3: q=33 rem=1; then 1 mod 3: q=0 rem=1
    flds f_3;   flds f_100;  fprem1; fprem1; fstp %st(0); fstp %st(0)
        # 100 mod 3: 33.33 -> Q=33 rem=1; then 1 mod 3: Q=0 rem=1

    # ---- remainder op adjacent to another engine user --------------------------
    # (the iterative configs share one unified divide/sqrt/remainder engine)
    flds f_3;   flds f_10;   fprem                  # st0=1, st1=3
    fdiv %st(1), %st(0)                             # st0 = 1/3
    fstp %st(0); fstp %st(0)
    flds f_2;   flds f_9;    fdiv %st(1), %st(0)    # st0 = 4.5, st1=2
    fprem                                         # 4.5 mod 2 = 0.5 (q=2)
    fstp %st(0); fstp %st(0)
    flds f_3;   flds f_16;   fprem1                 # 16 mod 3: Q=5, rem=1
    fsqrt                                         # sqrt(1) = 1
    fstp %st(0); fstp %st(0)

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
f_4:    .float  4.0
f_8:    .float  8.0
f_9:    .float  9.0
f_11:   .float  11.0
f_13:   .float  13.0
f_15:   .float  15.0
f_16:   .float  16.0
f_22:   .float  22.0
f_23:   .float  23.0
f_25:   .float  25.0
f_27:   .float  27.0
f_n0:   .long   0x80000000      # -0.0
f_pinf: .long   0x7F800000      # +inf (binary32)
f_qnan: .long   0x7FC00000      # quiet NaN (binary32)
    .align 2
cw_rne: .word   0x037F      # PC=64, RC=nearest, all exceptions masked
cw_dn:  .word   0x077F      # RC=down
cw_up:  .word   0x0B7F      # RC=up
cw_tz:  .word   0x0F7F      # RC=toward-zero
fsw_tmp: .word  0           # FNSTSW m16 scratch (the C2 poll target)
d_1_0:  .double 1.0
d_2_0:  .double 2.0
d_2_1:  .double 2.1
d_3_0:  .double 3.0
d_5_5:  .double 5.5
d_7_3:  .double 7.3
d_pi:   .double 3.14159265358979
d_1e10: .double 1.0e10
d_1e21: .double 1.0e21
d_1e30: .double 1.0e30
