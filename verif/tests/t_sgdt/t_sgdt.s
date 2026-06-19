# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# t_sgdt -- SGDT/SIDT (0F 01 /0, /1) to memory. Non-privileged, user-mode legal.
# Stores limit:base to the stack; never read back -> GPR/EFLAGS stream matches
# QEMU (GDTR/IDTR contents differ but live only in memory, which is not graded).
# NB: instruction 0 must not modify ESP (the harness reads init-ESP from the
# golden's n=0 record), so we lead with a register clear.
    .text
    .globl _start
_start:
    xorl  %eax, %eax
    subl  $32, %esp
    sgdt  (%esp)
    sidt  8(%esp)
    sgdtl 16(%esp)
    sidtl 24(%esp)
    addl  $32, %esp
    movl  $1, %eax
    xorl  %ebx, %ebx
    int   $0x80
