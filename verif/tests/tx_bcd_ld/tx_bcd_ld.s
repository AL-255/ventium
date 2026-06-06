# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M10 x87 test: tx_bcd_ld -- FBLD packed-BCD load (DF /4)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m3-fpu-spec.md, formerly "DEFERRED -- loud HALT"): FBLD loads an 80-bit
# packed-BCD integer (18 digits + sign byte) from memory, converts it to floatx80,
# and pushes it. All inputs are exact integers, so the floatx80 result is exact and
# unambiguous -- st0..st(n) are live-graded vs QEMU as raw 80-bit, AND one result is
# read back through FISTP into a GPR as a defensive integer cross-check.
#
# Packed-BCD memory format (little-endian): bytes[0..8] hold 18 BCD digits, 2 per
# byte, byte0 = the two LEAST-significant digits; byte9 = sign (bit7: 1=negative).
#   +1234567 -> 67 45 23 01 00 00 00 00 00 | 00
#   -1234567 -> 67 45 23 01 00 00 00 00 00 | 80
#   +123456789012 -> 12 90 78 56 34 12 00 00 00 | 00
#
# Exit: Linux i386 _exit(0) -> int 0x80 (core HALT).
# =============================================================================

    .text
    .globl  _start
_start:
    fninit                          # clean x87 state (stack empty, default cw)

    fbld    bcd_p1234567            # st0 = +1234567
    fbld    bcd_n1234567            # st0 = -1234567, st1 = +1234567
    fbld    bcd_big                 # st0 = +123456789012, st1=-1234567, st2=+1234567
    fbld    bcd_zero                # st0 = +0, st1.., (all four live-graded)

    # defensive integer cross-check: reload +1234567 and surface it as a GPR int64
    fbld    bcd_p1234567            # st0 = +1234567 (pushes, st-depth now 5)
    fistpll out_i64                 # store int64 1234567, pop
    movl    out_i64,   %eax         # eax = 0x0012D687 (1234567)
    movl    out_i64+4, %edx         # edx = 0

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx
    int     $0x80                   # halt

    # =========================================================================
    .data
    .align 16
bcd_p1234567: .byte 0x67,0x45,0x23,0x01,0x00,0x00,0x00,0x00,0x00, 0x00
bcd_n1234567: .byte 0x67,0x45,0x23,0x01,0x00,0x00,0x00,0x00,0x00, 0x80
bcd_big:      .byte 0x12,0x90,0x78,0x56,0x34,0x12,0x00,0x00,0x00, 0x00
bcd_zero:     .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00
out_i64:      .quad 0
