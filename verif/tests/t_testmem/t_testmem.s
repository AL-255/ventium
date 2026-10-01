# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# TEST r/m,reg must AND the memory operand with the encoded register, not EAX.
    .text
    .globl _start
_start:
    # Win95 VMM's failing shape: TEST [global],EBX with an unrelated EAX.
    movl $0x00000206, %eax
    movl $0xa0060000, %ebx
    movl $0x80000188, flag32
    testl %ebx, flag32
    jz fail
    cmpl $0x80000188, flag32
    jne fail

    # Complementary zero case: using EAX instead of EBX reverses ZF.
    movl $0x80000000, %eax
    movl $0x40000000, %ebx
    movl $0x80000000, flag32
    testl %ebx, flag32
    jnz fail
    cmpl $0x80000000, flag32
    jne fail

    # The same operand-role contract applies to 66/85 and 84 encodings.
    movw $0x0206, %ax
    movw $0x8000, %bx
    movw $0x8001, flag16
    testw %bx, flag16
    jz fail
    cmpw $0x8001, flag16
    jne fail

    movb $0x06, %al
    movb $0x80, %bl
    movb $0x81, flag8
    testb %bl, flag8
    jz fail
    cmpb $0x81, flag8
    jne fail

    # High-byte register encoding must select BH, not BL or AL.
    movb $0x80, %bh
    movb $0x06, %al
    testb %bh, flag8
    jz fail
    cmpb $0x81, flag8
    jne fail

    movl $1, %eax
    xorl %ebx, %ebx
    int $0x80
fail:
    movl $1, %eax
    movl $1, %ebx
    int $0x80

    .data
    .align 4
flag32: .long 0
flag16: .word 0
flag8:  .byte 0
