# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# t_divw -- 8-bit and 16-bit DIV/IDIV (q_w==1 / q_w==2 divide-width arms in
# core_gpr_wb.svh that the 32-bit-only t_div never reaches). No #DE: quotients fit.
    .text
    .globl _start
_start:
    # DIV r8 : AL = AX / r8 , AH = AX % r8
    movw  $0x0041, %ax        # 65
    movb  $0x07, %bl
    divb  %bl                 # AL=9 AH=2
    movw  $0x00ff, %ax
    movb  $0x10, %cl
    divb  %cl                 # AL=0x0F AH=0x0F
    # IDIV r8 : signed
    movw  $0xfff6, %ax        # -10
    movb  $0x03, %bl          # 3
    idivb %bl                 # AL=-3=0xFD AH=-1=0xFF
    # DIV r16 : AX = DX:AX / r16 , DX = rem
    xorw  %dx, %dx
    movw  $0x3039, %ax        # 12345
    movw  $0x000a, %bx        # 10
    divw  %bx                 # AX=1234 DX=5
    movw  $0x0001, %dx
    movw  $0x0000, %ax        # DX:AX = 0x10000
    movw  $0x0003, %cx
    divw  %cx                 # AX=0x5555 DX=1
    # IDIV r16 : signed
    movw  $0xffff, %dx
    movw  $0xff9c, %ax        # DX:AX = -100
    movw  $0x0007, %bx
    idivw %bx                 # AX=-14 DX=-2
    # exit
    movl  $1, %eax
    xorl  %ebx, %ebx
    int   $0x80
