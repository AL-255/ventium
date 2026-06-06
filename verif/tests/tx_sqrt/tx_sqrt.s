# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M3 test: tx_sqrt -- x87 FSQRT (Tier-2 arithmetic)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Covers (docs/m3-fpu-spec.md Tier 2, default control word 0x037f =
# round-nearest-even, 64-bit precision):
#   FSQRT  (D9 FA)  -- ST(0) <- sqrt(ST(0)), on NORMAL non-negative operands.
#
# Operand mix (EXACT vs ROUNDING confirmed against QEMU's PE/precision bit):
#   EXACT (perfect squares -> exact integer/dyadic root, PE=0):
#     sqrt(4)=2, sqrt(9)=3, sqrt(16)=4, sqrt(2.25)=1.5, sqrt(6.25)=2.5,
#     sqrt(0.25)=0.5, sqrt(1)=1, sqrt(2^k) for even k.
#   ROUNDING (irrational root -> round-near-even, PE latches):
#     sqrt(2), sqrt(3), sqrt(10), sqrt(2^k) for odd k (= 2^(k/2)*sqrt(2)).
#   The diff only has to MATCH QEMU's rounded floatx80; we don't hand-predict it.
#
# Source operands are all positive normals; sqrt of a non-negative normal never
# raises (#IA only on negative operand, which we avoid). Exceptions stay masked
# (default cw). Deterministic. Ends with Linux i386 _exit(0) (int 0x80 = HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---------------------------------------------------------------------
    # (A) PERFECT SQUARES -- exact roots, PE stays 0
    # ---------------------------------------------------------------------
    flds    f_4                     # st0 = 4.0
    fsqrt                           # st0 = 2.0                 EXACT
    fstp    %st(0)

    flds    f_9                     # st0 = 9.0
    fsqrt                           # st0 = 3.0                 EXACT
    fstp    %st(0)

    flds    f_16                    # st0 = 16.0
    fsqrt                           # st0 = 4.0                 EXACT
    fstp    %st(0)

    flds    f_2p25                  # st0 = 2.25 (= 1.5^2)
    fsqrt                           # st0 = 1.5                 EXACT
    fstp    %st(0)

    flds    f_6p25                  # st0 = 6.25 (= 2.5^2)
    fsqrt                           # st0 = 2.5                 EXACT
    fstp    %st(0)

    flds    f_0p25                  # st0 = 0.25 (= 0.5^2)
    fsqrt                           # st0 = 0.5                 EXACT
    fstp    %st(0)

    flds    f_1                     # st0 = 1.0
    fsqrt                           # st0 = 1.0                 EXACT
    fstp    %st(0)

    fildl   i_64                    # st0 = 64.0 (= 8^2)
    fsqrt                           # st0 = 8.0                 EXACT
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # (B) NON-SQUARES -- irrational roots, round-near-even, PE latches
    # ---------------------------------------------------------------------
    flds    f_2                     # st0 = 2.0
    fsqrt                           # st0 = sqrt(2) ~ 1.4142..  ROUNDING
    fstp    %st(0)

    flds    f_3                     # st0 = 3.0
    fsqrt                           # st0 = sqrt(3) ~ 1.7320..  ROUNDING
    fstp    %st(0)

    flds    f_10                    # st0 = 10.0
    fsqrt                           # st0 = sqrt(10) ~ 3.1622.. ROUNDING
    fstp    %st(0)

    fildl   i_2                     # st0 = 2.0 (integer load)
    fsqrt                           # st0 = sqrt(2)             ROUNDING
    fstp    %st(0)

    flds    f_8                     # st0 = 8.0 (= 2^3, odd power)
    fsqrt                           # st0 = 2*sqrt(2)           ROUNDING
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # (C) chained: sqrt of a sqrt -- exact then exact (16 -> 4 -> 2)
    # ---------------------------------------------------------------------
    flds    f_16                    # st0 = 16.0
    fsqrt                           # st0 = 4.0                 EXACT
    fsqrt                           # st0 = 2.0                 EXACT
    fstp    %st(0)

    # ---------------------------------------------------------------------
    # clean exit: Linux i386 _exit(0)
    # ---------------------------------------------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    # =========================================================================
    .data
    .align 8
f_1:     .float  1.0
f_2:     .float  2.0
f_3:     .float  3.0
f_4:     .float  4.0
f_8:     .float  8.0
f_9:     .float  9.0
f_10:    .float  10.0
f_16:    .float  16.0
f_2p25:  .float  2.25
f_6p25:  .float  6.25
f_0p25:  .float  0.25
i_2:     .long   2
i_64:    .long   64
