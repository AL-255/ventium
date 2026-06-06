# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M3 x87 test: tx_fcomnan -- FCOM vs FUCOM #IA on NaN operands (Tier 1)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Regression for adversarial-review finding [low]: the SIGNALING compares
# (FCOM/FCOMP/FCOMPP/FTST/FICOM, floatx80_compare) raise the invalid flag IE
# (fstat bit0) on ANY NaN operand, while the QUIET compares (FUCOM/FUCOMP/
# FUCOMPP, floatx80_compare_quiet) raise IE only on a SIGNALING NaN.
# (QEMU helper_fcom_ST0_FT0 / helper_fucom_ST0_FT0, fpu_helper.c:458-476.)
#
# Four cases, exceptions MASKED (no fault), each preceded by FNCLEX:
#   FCOM  vs QNaN  -> unordered (0x4500) + IE
#   FUCOM vs QNaN  -> unordered (0x4500), NO IE
#   FCOM  vs SNaN  -> unordered + IE
#   FUCOM vs SNaN  -> unordered + IE  (SNaN signals even on the quiet compare)
# The SNaN is loaded as an m80 (FLDT) so the FLD does not quiet it (a float64
# SNaN would be quieted by the float64->floatx80 conversion). fstat is trace-
# compared, so the C-codes AND IE bit must match QEMU exactly.
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    fnclex
    # FCOM vs QNaN -> unordered + IE
    fld1
    fldl    qnan
    fcom    %st(1)
    fnstsw  %ax
    fstp    %st(0)
    fstp    %st(0)

    fnclex
    # FUCOM vs QNaN -> unordered, NO IE
    fld1
    fldl    qnan
    fucom   %st(1)
    fnstsw  %ax
    fstp    %st(0)
    fstp    %st(0)

    fnclex
    # FCOM vs SNaN(m80) -> unordered + IE
    fld1
    fldt    snan80
    fcom    %st(1)
    fnstsw  %ax
    fstp    %st(0)
    fstp    %st(0)

    fnclex
    # FUCOM vs SNaN(m80) -> unordered + IE (SNaN signals even for quiet compare)
    fld1
    fldt    snan80
    fucom   %st(1)
    fnstsw  %ax
    fstp    %st(0)
    fstp    %st(0)

    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    # =========================================================================
    .data
    .align 16
qnan:   .quad 0x7FF8000000000000      # double quiet NaN
snan80: .quad 0x8000000000000001      # floatx80: exp all-ones, bit62=0, low bit set -> SNaN
        .word 0x7fff
        .word 0
