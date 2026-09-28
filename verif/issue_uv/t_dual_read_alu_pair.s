# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# U MOV dword + independent V ALU reg,[mem]. MODE=0 ADD; MODE=1 CMP.
# SECOND_OFFSET=4 admits a different L1 bank, 0 conflicts, 32 crosses a line.
.ifndef MODE
.set MODE, 0
.endif
.ifndef SECOND_OFFSET
.set SECOND_OFFSET, 4
.endif
.text
.globl _start
_start:
    movl $arena, %esi
    movl $arena, %edi
    movl $1000, %ecx
    movl $0x345, %ebx
.balign 32
.globl loop_body
loop_body:
.globl first_load
first_load:
    movl (%esi), %eax
.globl second_alu
second_alu:
.if MODE == 0
    addl SECOND_OFFSET(%edi), %ebx
.else
    cmpl SECOND_OFFSET(%edi), %ebx
.endif
    decl %ecx
    jnz loop_body
    movl $1, %eax
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 4096
arena:
    .long 0x89abcdef, 0x345
    .zero 8192-8
