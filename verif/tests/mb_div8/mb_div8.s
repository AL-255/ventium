# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# mb_div8 — DIV r/m8 occupancy microbenchmark (p5model occ=17, NP, U-pipe held).
# Fast-pathed movl setup isolates the divide; AX=0xFE / 7 = 36 r 2 (no quotient
# overflow, so QEMU does not #DE — the occupancy, not the fault, is under test).
    .text
    .globl _start
_start:
    movl    $400, %ecx
.Lrep:
    movl    $0x000000FE, %eax
    movl    $0x07, %ebx
    divb    %bl
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
