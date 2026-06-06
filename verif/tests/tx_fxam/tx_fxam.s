# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M3 x87 test: tx_fxam -- FXAM classify across ALL classes (Tier 1)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Regression for adversarial-review finding [high]: FXAM on an Infinity must set
# condition codes 0x500 (C2+C0), NOT 0x4100 (C3+C0). This program classifies
# every floatx80 class FXAM distinguishes and checks fstat (and FNSTSW AX):
#   +Inf  -> C3C2C1C0 = 0101 (0x0500)          [was mis-encoded before the fix]
#   -Inf  -> 0x0700 (C2+C1+C0, C1=sign)
#   QNaN  -> 0x0100 (C0)
#   +Normal 2.0 -> 0x0400 (C2)
#   +Zero -> 0x4000 (C3)
#   -Zero -> 0x4200 (C3+C1)
#   Empty -> 0x4100 (C3+C0)
# (QEMU helper_fxam_ST0: fpu_helper.c:2331; C1 = sign bit, overlaid in all cases.)
# All operands are non-faulting (FXAM never raises #IA); exceptions stay masked.
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    # +Inf -> 0x0500 (C2+C0)
    fldt    pinf80
    fxam
    fnstsw  %ax
    fstp    %st(0)

    # -Inf -> 0x0700 (C2+C1+C0)
    fldt    ninf80
    fxam
    fnstsw  %ax
    fstp    %st(0)

    # QNaN -> 0x0100 (C0)
    fldl    qnan
    fxam
    fnstsw  %ax
    fstp    %st(0)

    # +Normal 2.0 -> 0x0400 (C2)
    flds    f2_0
    fxam
    fnstsw  %ax
    fstp    %st(0)

    # +Zero -> 0x4000 (C3) ; -Zero -> 0x4200 (C3+C1)
    fldz
    fxam
    fnstsw  %ax
    fchs                    # -0.0
    fxam
    fnstsw  %ax
    fstp    %st(0)

    # Empty -> 0x4100 (C3+C0)
    fxam
    fnstsw  %ax

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    # =========================================================================
    .data
    .align 16
pinf80: .quad 0x8000000000000000      # mantissa
        .word 0x7fff                  # +Inf : sign 0, exp all-ones
        .word 0
ninf80: .quad 0x8000000000000000
        .word 0xffff                  # -Inf : sign 1, exp all-ones
        .word 0
qnan:   .quad 0x7FF8000000000000      # double-precision quiet NaN
f2_0:   .float 2.0
