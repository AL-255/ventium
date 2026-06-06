# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M3 x87 test: tx_storeflags -- store-path PE/IE status (Tier 1)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Regression for adversarial-review finding [med]: FST m32/m64 and FIST m16/m32/
# m64 must latch the precision flag PE (fstat bit5) when the store rounds, and
# FIST must latch the invalid flag IE (bit0, with integer-indefinite result)
# when the value is out of the destination's range. QEMU latches these via
# helper_fsts/fstl/fist* -> merge_exception_flags (fpu_helper.c:275-339).
#
# Sequence (all exceptions MASKED -> default cw; PE/IE just accumulate sticky):
#   1. FST m32 of a value not exactly representable in float32 -> PE.
#   2. FST m64 of a value not exactly representable in float64 -> PE (still set).
#   3. FNCLEX to clear, then FIST m32 of a NON-integer (2.5) -> PE only.
#   4. FNCLEX, then FIST m16 of 100000 (out of int16 range) -> IE + indefinite.
# fstat is trace-compared, so PE/IE must match QEMU exactly.
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    fnclex                          # status clean

    # 1. FST m32 of 1.2345678901234567 (double) -> narrow rounds -> PE
    fldl    d_inexact
    fsts    out32                   # store-no-pop; PE latched
    fnstsw  %ax
    fstp    %st(0)

    # 2. FNCLEX then FST m64 of a value needing >52 fraction bits -> PE
    fnclex
    fldt    e_inexact               # m80 with low mantissa bits set
    fstl    out64                   # narrow to double rounds -> PE
    fnstsw  %ax
    fstp    %st(0)

    # 3. FNCLEX then FIST m32 of 2.5 (non-integer) -> PE only (in range)
    fnclex
    flds    f2_5
    fistl   out32                   # round-to-even -> 2, inexact -> PE
    fnstsw  %ax
    fstp    %st(0)

    # 4. FNCLEX then FIST m16 of 100000 (> int16 max 32767) -> IE + indefinite
    fnclex
    flds    f100000
    fists   out16                   # out of int16 range -> IE, store 0x8000
    fnstsw  %ax
    fstp    %st(0)

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    # =========================================================================
    .data
    .align 16
d_inexact: .double 1.2345678901234567   # not exactly representable in float32
# floatx80 with mantissa bits below bit11 set -> not representable in float64.
# value ~ 1.0000000000000000542; mantissa 0x8000000000000400, exp 0x3fff.
e_inexact: .quad 0x8000000000000400
           .word 0x3fff
           .word 0
f2_5:      .float 2.5
f100000:   .float 100000.0
out32:     .long 0
out64:     .quad 0
out16:     .short 0
