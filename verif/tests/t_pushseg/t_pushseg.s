# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# t_pushseg -- PUSH segment-register forms ES/CS/SS/DS (06/0E/16/1E) in the slow
# decoder (decode_stages.sv:711-717). The selector pushed lands in memory (not
# graded); only ESP is graded, so we discard the pushed bytes to rebalance. If
# the core and QEMU disagree on push-seg operand size this will surface as an ESP
# divergence (a real finding).
    .text
    .globl _start
_start:
    xorl  %eax, %eax
    push  %es                   # 06
    addl  $4, %esp
    push  %cs                   # 0E
    addl  $4, %esp
    push  %ss                   # 16
    addl  $4, %esp
    push  %ds                   # 1E
    addl  $4, %esp
    movl  $1, %eax
    xorl  %ebx, %ebx
    int   $0x80
