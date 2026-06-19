# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# t_farjmp -- LONG-form near JMP rel32 (E9) and Jcc rel32 (0F 8x). The corpus
# only uses the short rel8 forms (EB / 7x); >127-byte targets force the rel32
# encodings (decode_stages.sv:447 Jcc 0F 8x, :1223 JMP E9). Padding is jumped
# over, never executed.
    .text
    .globl _start
_start:
    movl  $1, %eax
    jmp   j1
    .fill 300, 1, 0xcc
j1:
    cmpl  $1, %eax
    je    j2                # forward >127 -> 0F 84 rel32
    .fill 300, 1, 0xcc
j2:
    cmpl  $2, %eax
    jne   j3                # 0F 85 rel32
    .fill 300, 1, 0xcc
j3:
    testl %eax, %eax
    jg    j4                # 0F 8F rel32
    .fill 300, 1, 0xcc
j4:
    movl  $1, %eax
    xorl  %ebx, %ebx
    int   $0x80
