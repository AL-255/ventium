# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M3 x87 test: tx_round -- directed rounding control RC (Tier 2/3)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Regression for adversarial-review finding [med]: arithmetic under a control
# word with RC != 00 must round per RC (QEMU update_fp_status maps RC ->
# float_rounding_mode). This pulls the directed-rounding modes into the GATED
# set. PRECISION control (PC) is kept at 11 (64-bit extended) throughout, so
# only RC varies -- non-default PC remains a deferred (loud-HALT) Tier-3 corner.
#
# Control words (PC=11 64-bit, all masks set; only RC field changes):
#   0x0f7f = RC 11 toward zero
#   0x0b7f = RC 10 toward +inf
#   0x077f = RC 01 toward -inf
# Each computes 10.0/3.0 (a value with no exact extended-precision form), so the
# three modes give three DIFFERENT 80-bit results and PE is set each time.
# st0 and fstat (PE bit5) are trace-compared -> must match QEMU bit-exact.
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- RC = toward zero (truncate) ----------------------------------------
    fldcw   cw_tz
    flds    ten
    flds    three
    fdivp   %st(0),%st(1)           # 10/3 toward zero
    fnstsw  %ax
    fstp    %st(0)

    # ---- RC = toward +inf ---------------------------------------------------
    fldcw   cw_up
    flds    ten
    flds    three
    fdivp   %st(0),%st(1)           # 10/3 toward +inf
    fnstsw  %ax
    fstp    %st(0)

    # ---- RC = toward -inf ---------------------------------------------------
    fldcw   cw_dn
    flds    ten
    flds    three
    fdivp   %st(0),%st(1)           # 10/3 toward -inf
    fnstsw  %ax
    fstp    %st(0)

    # ---- back to round-nearest, an exact op (no PE) -------------------------
    fldcw   cw_rn
    flds    ten
    flds    two
    fmulp   %st(0),%st(1)           # 10*2 = 20.0 exact
    fnstsw  %ax

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    # =========================================================================
    .data
    .align 16
cw_tz:  .word 0x0f7f                # RC=11 toward zero, PC=11 64-bit
cw_up:  .word 0x0b7f                # RC=10 toward +inf, PC=11
cw_dn:  .word 0x077f                # RC=01 toward -inf, PC=11
cw_rn:  .word 0x037f                # default: RC=00 nearest, PC=11
ten:    .float 10.0
three:  .float 3.0
two:    .float 2.0
