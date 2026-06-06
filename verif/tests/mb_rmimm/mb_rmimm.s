# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# mb_rmimm — AP-500 reg-form r/m32,imm32 fast-path pairing microbenchmark
# (review Action 6, batch 2). Each general-register `ALU r/m32,imm32` (81 /r) or
# `MOV r/m32,imm32` (C7 /0) — U — is interleaved with an independent `mov reg,reg`
# (V): with these reg-form imm32 short forms now fast-pathed they PAIR (pairing%
# ~50, matching p5model); before batch 2 they fell to the slow FSM (~0% pairing).
    .text
    .globl _start
_start:
    movl    $400, %ecx
    movl    $0x12345678, %esi
.Lrep:
    addl    $0x11111111, %ebx
    movl    %esi, %eax
    movl    $0x22222222, %edx
    movl    %esi, %edi
    andl    $0x7FFFFFFF, %ebx
    movl    %esi, %ebp
    xorl    $0x55555555, %edx
    movl    %esi, %eax
    decl    %ecx
    jnz     .Lrep
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
