# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium #11 x87 test: tx_f2xm1 — F2XM1 (2^x - 1), D9 F0.
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as. Built like the
# rest of the corpus (gcc -m32 -march=pentium -nostdlib -static -Ttext=0x08048000).
#
# F2XM1 is DEFERRED in the default build (decode -> d_unknown -> HALT). This test
# is only meaningful under +VEN_TRANSCENDENTAL (the fpu_f2xm1 engine), so it lives
# under verif/trsc/ (NOT the default corpus) and is driven by run-f2xm1-core-gate.sh,
# which builds the cosim TB with +VEN_TRANSCENDENTAL and func-diffs st0..st7 / fctrl
# / fstat / ftag vs the qemu-i386 gdbstub golden (compare.py --mode func, exact).
#
# Coverage: every helper_f2xm1 branch — the +-1 / 0 exact corners, the polynomial
# interval (|x|<1), a near-1 argument, and the tiny ln2 fast-path (|x|<2^-79). The
# golden + RTL must agree to the bit on the result AND the PE/fstat status.
# =============================================================================
    .text
    .globl  _start
_start:
    # ---- exact corners: 2^0-1=0, 2^1-1=1, 2^-1-1=-0.5 -----------------------
    fldz
    f2xm1                   # 0
    fstp    %st(0)
    fld1
    f2xm1                   # +1.0
    fstp    %st(0)
    fld1
    fchs
    f2xm1                   # -0.5 (f2xm1 of -1)
    fstp    %st(0)

    # ---- polynomial interval + tiny ln2 path (mem constants) ----------------
    fldt    v_0p5 ;  f2xm1 ; fstp %st(0)
    fldt    v_m0p5;  f2xm1 ; fstp %st(0)
    fldt    v_0p25;  f2xm1 ; fstp %st(0)
    fldt    v_m0p75; f2xm1 ; fstp %st(0)
    fldt    v_third; f2xm1 ; fstp %st(0)
    fldt    v_0p9;   f2xm1 ; fstp %st(0)
    fldt    v_63_64; f2xm1 ; fstp %st(0)
    fldt    v_m63_64;f2xm1 ; fstp %st(0)
    fldt    v_near1; f2xm1 ; fstp %st(0)
    fldt    v_mnear1;f2xm1 ; fstp %st(0)
    fldt    v_tiny1; f2xm1 ; fstp %st(0)   # ln2 fast-path (|x|<2^-79)
    fldt    v_tiny2; f2xm1 ; fstp %st(0)

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 16
v_0p5:    .tfloat  0.5
v_m0p5:   .tfloat -0.5
v_0p25:   .tfloat  0.25
v_m0p75:  .tfloat -0.75
v_third:  .tfloat  0.3333333333333333333
v_0p9:    .tfloat  0.9
v_63_64:  .tfloat  0.984375
v_m63_64: .tfloat -0.984375
v_near1:  .tfloat  0.99999999
v_mnear1: .tfloat -0.99999999
v_tiny1:  .tfloat  5e-25
v_tiny2:  .tfloat -1e-25
