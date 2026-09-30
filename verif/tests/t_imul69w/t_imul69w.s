# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Opcode69's immediate follows OPERAND size, not the address/default size.
# NOP+INC sentinels expose overconsuming two bytes after every word operation.
    .text
    .globl _start
_start:
    xorl %edi, %edi
    movl $0xa5b60001, %eax
    movl $3, %ebx
    movl $0x24680000, %ecx
    movl $0x13570000, %edx
    movl $0x87650000, %ebp
    imulw $0x1234, %bx, %ax
    nop
    incl %edi
    imulw $-300, %bx, %ax
    nop
    incl %edi
    imulw $0x1234, positive, %cx
    nop
    incl %edi
    imulw $-300, negative, %dx
    nop
    incl %edi
    movl $arena, %esi
    imulw $0x3456, 2(%esi,%ebx,2), %bp
    nop
    incl %edi
    cmpl $5, %edi
    jne .Lfail
    xorl %ebx, %ebx
    jmp .Lexit
.Lfail:
    movl $1, %ebx
.Lexit:
    movl $1, %eax
    int $0x80
    .data
    .balign 32
positive: .word 3
negative: .word -2
arena: .long 0,0
       .word -3
