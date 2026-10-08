/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Genuine U/V pair-state regression; no forced pair or debugger assistance.
 */
#ifndef CASE
#define CASE 0
#endif
.text
.global _start, uv_subject, uv_younger, uv_after
_start:
    movl $0x80000001, %eax
    movl $0x7fffffff, %ebx
    movl $0x12340000, %ecx
    movl $0x56780000, %edx
    movl $0xa5a55a5a, %esi
    movl $cell, %edi
    testl %eax, %eax
    jmp uv_subject
    .p2align 5, 0x90
uv_subject:
#if CASE == 0
    movl $0x90000, %esp
#elif CASE == 1 || CASE == 2
    addl $1, %eax
#elif CASE == 3
    movb $0x33, %ah
#elif CASE == 4
    movw $0xaaaa, %ax
#elif CASE == 5
    movl (%edi), %eax
#elif CASE == 6
    movl %eax, (%edi)
#elif CASE == 7
    leal 4(%eax), %ecx
#elif CASE == 8
    cmpl %eax, %eax
#elif CASE == 9
    shrl $1, %eax
#elif CASE == 10
    .byte 0xc1, 0xc8, 1 /* ROR EAX,imm8 */
#elif CASE == 11
    movl %esi, %eax
#else
#error unknown CASE
#endif
uv_younger:
#if CASE == 0
    movl $0x11111111, %eax
#elif CASE == 1
    movl $0x33333333, %ecx
#elif CASE == 3
    movb $0x77, %bl
#elif CASE == 7
    movl $0x12345678, %edx
#elif CASE == 9
    incl %ebx
#elif CASE == 10
    decl %ebx
#elif CASE == 11
    leal 8(%edx), %ecx
#else
    addl $3, %ebx
#endif
uv_after:
    /* Record the memory effect as well as both per-instruction states. */
    movl (%edi), %esi
    movl $0x42, %ebp
    movl $0, %ebx
    movl $1, %eax
    int $0x80
.data
    .p2align 5
cell:
    .long 0xa55a1234
