# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Two independent U-load/V-ALU-memory pairs with no intervening register group.
# Detects a design that retires memory ALUs at one pair per EX clock.
.ifndef UMODE
.set UMODE, 0
.endif
.text
.globl _start
_start:
    movl $arena, %esi
    movl $arena, %edi
    movl $1000, %ecx
    movl $3, %ebx
    movl $7, %ebp
    xorl %eax, %eax
    xorl %edx, %edx
.balign 32
.globl loop_body
loop_body:
.globl first_load
first_load:
.if UMODE == 0
    movl (%esi), %eax
.else
    addl (%esi), %eax
.endif
.globl second_alu
second_alu:
    addl 4(%edi), %ebx
.globl third_load
third_load:
.if UMODE == 0
    movl 8(%esi), %edx
.else
    addl 8(%esi), %edx
.endif
.globl fourth_alu
fourth_alu:
    xorl 12(%edi), %ebp
    decl %ecx
    jnz loop_body
    movl $1, %eax
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 4096
arena:
    .long 0x11111111, 0x22, 0x33333333, 0x44
    .zero 8192-16
