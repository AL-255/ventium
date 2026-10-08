/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Eight independent UV regressions. Each subject starts a cache line and is
 * reached by a jump, so it cannot be consumed as an older instruction's V.
 */
#ifndef CASE
#define CASE 0
#endif
.text
.global _start, uv_subject, uv_branch, uv_taken, uv_fail
_start:
    movl $CASE, %ebp
    xorl %ebx, %ebx
#if CASE == 0 || CASE == 2
    movl $0xa55a0040, %eax
#elif CASE == 1 || CASE == 3
    movl $0xa55a4000, %eax
#elif CASE == 4
    incl %ebx                    /* ZF=0, despite ROR's zero result */
    movl $0, %eax
#elif CASE == 5
    movl $1, %eax                /* ZF=1, despite ROR's nonzero result */
#elif CASE == 6
    movl $0x80000000, %ebx
    testl %ebx, %ebx             /* SF=1, despite ROR's positive result */
    movl $2, %eax
#elif CASE == 7
    movl $2, %eax                /* PF=1, despite odd-parity ROR result */
#else
#error unknown CASE
#endif
    jmp uv_subject
    .p2align 5, 0x90
uv_subject:
#if CASE == 0 || CASE == 2
    shlb $1, %al
#elif CASE == 1 || CASE == 3
    shlw $1, %ax
#else
    .byte 0xc1, 0xc8, 1          /* ROR EAX,imm8; do not assemble as D1 */
#endif
uv_branch:
#if CASE == 0 || CASE == 1 || CASE == 6
    js uv_taken
#elif CASE == 2 || CASE == 3
    jo uv_taken
#elif CASE == 4
    jnz uv_taken
#elif CASE == 5
    jz uv_taken
#else
    jp uv_taken
#endif
uv_fail:
    movl $0xee, %ebp
    movl $1, %ebx
    movl $1, %eax
    int $0x80
uv_taken:
    movl $0x42, %ebp
    movl $0, %ebx
    movl $1, %eax
    int $0x80
