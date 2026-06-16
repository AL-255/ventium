# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium test: t_grp1alias  --  0x82 (undocumented group-1 r/m8, imm8 alias)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# 0x82 is an undocumented one-byte alias of 0x80 (group-1 r/m8, imm8): same
# ModRM /digit -> ALU op, same imm8, same flags. Real P5 silicon and QEMU decode
# it identically. The assembler will not emit 0x82, so the opcodes are hand-
# encoded with .byte; the result register + all flags are differentially checked
# vs QEMU. /digit: 0 ADD,1 OR,2 ADC,3 SBB,4 AND,5 SUB,6 XOR,7 CMP.
# =============================================================================

    .text
    .globl  _start
_start:

    # ---- 0x82 /0  ADD BL, 0x05   (ModRM C3 = mod11 reg000 rm011=BL) ---
    movl    $0x10, %ebx
    .byte   0x82, 0xC3, 0x05        # add bl, 5  -> bl=0x15, flags from 0x10+5

    # ---- 0x82 /5  SUB BL, 0x03   (ModRM EB = mod11 reg101 rm011=BL) ---
    movl    $0x20, %ebx
    .byte   0x82, 0xEB, 0x03        # sub bl, 3  -> bl=0x1D

    # ---- 0x82 /7  CMP CL, 0x10   (ModRM F9 = mod11 reg111 rm001=CL) ---
    movl    $0x10, %ecx
    .byte   0x82, 0xF9, 0x10        # cmp cl, 0x10 -> ZF=1, no writeback

    # ---- 0x82 /4  AND AL, 0x0F   (ModRM E0 = mod11 reg100 rm000=AL) ---
    movl    $0x000000FF, %eax
    .byte   0x82, 0xE0, 0x0F        # and al, 0x0F -> al=0x0F

    # ---- 0x82 /6  XOR DL, 0xFF   (ModRM F2 = mod11 reg110 rm010=DL) ---
    movl    $0x0000005A, %edx
    .byte   0x82, 0xF2, 0xFF        # xor dl, 0xFF -> dl=0xA5

    # ---- clean exit: Linux i386 _exit(0) -------------------------------
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
