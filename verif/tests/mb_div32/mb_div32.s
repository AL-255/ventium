# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# mb_div32 — independent DIV r/m32 occupancy microbenchmark.
# Each iteration reloads EDX:EAX + divisor and does one DIVL (32/32). p5model
# charges DIV r/m32 occ=41 (NP, U-pipe held). The surrounding mov/xor/dec/jnz are
# ~1 cyc each, so per-iteration cycles are dominated by the divide occupancy.
    .text
    .globl _start
_start:
    movl    $400, %ecx
.Lrep:
    movl    $0x00C0FFEE, %eax
    xorl    %edx, %edx
    movl    $7, %ebx
    divl    %ebx                # EDX:EAX / EBX -> EAX=quot, EDX=rem
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
