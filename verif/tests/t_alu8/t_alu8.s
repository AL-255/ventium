# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# t_alu8 -- 8-bit ALU in the r8 <- r/m8 (d=1) direction (02/0A/12/1A/22/2A/32/3A)
# incl. a memory source, covering decode_stages.sv:789 (ALU r8, r/m8) which the
# existing tests miss (they use the r/m8,r8 / 32-bit forms).
    .text
    .globl _start
_start:
    xorl  %eax, %eax
    subl  $16, %esp
    movb  $0x3c, (%esp)          # a byte in memory
    movb  $0x12, %al
    addb  (%esp), %al            # 02 /r  ADD r8, r/m8 (mem src)
    orb   (%esp), %al            # 0A /r
    adcb  (%esp), %al            # 12 /r
    sbbb  (%esp), %al            # 1A /r
    andb  $0x7f, %al
    andb  (%esp), %al            # 22 /r
    subb  (%esp), %al            # 2A /r
    xorb  (%esp), %al            # 32 /r
    cmpb  (%esp), %al            # 3A /r
    movb  $0x44, %bl
    addb  %bl, %al               # 02 reg form too
    addl  $16, %esp
    movl  $1, %eax
    xorl  %ebx, %ebx
    int   $0x80
