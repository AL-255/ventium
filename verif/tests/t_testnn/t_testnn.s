# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# t_testnn -- TEST AL,imm8 (A8) + TEST eAX,imm (A9) + group-3 TEST/NOT/NEG in
# byte and word widths (F6/F7 /0,/2,/3) covering decode_stages width arms
# (:1027 A8, :1120-1124 TEST imm, :1136-1139 NOT/NEG byte/word).
    .text
    .globl _start
_start:
    movl  $0xdeadbeef, %eax
    testb $0x0f, %al          # A8 TEST AL,imm8
    testw $0x00f0, %ax        # 66 A9 TEST AX,imm16
    testl $0x12345678, %eax   # A9 TEST EAX,imm32
    movb  $0x55, %bl
    testb $0x0f, %bl          # F6 /0 TEST r/m8,imm8
    movw  $0x1234, %cx
    testw $0x0ff0, %cx        # F7 /0 TEST r/m16,imm16
    movb  $0x0f, %dl
    notb  %dl                 # F6 /2 NOT r/m8
    negb  %dl                 # F6 /3 NEG r/m8
    movw  $0x00ff, %si
    notw  %si                 # F7 /2 NOT r/m16
    negw  %si                 # F7 /3 NEG r/m16
    movl  $1, %eax
    xorl  %ebx, %ebx
    int   $0x80
