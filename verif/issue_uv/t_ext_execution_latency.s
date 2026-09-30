// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// MOVSX/MOVZX: NP, one ordinary 0F D1 clock plus three EX clocks.
// Six instructions per loop, compatible with run-load-issue-ipc.sh.
.text
.globl _start
_start:
    movl $1000, %ecx
    movl $arena, %esi
    xorl %edx, %edx
    jmp loop_body
.balign 32
.globl loop_body
loop_body:
.ifdef BYTE_HIGH
.ifdef COUNT_UP
    movswl (%esi), %eax
.else
    movzwl (%esi), %eax
.endif
.else
.ifdef DEPENDENT
    movsbl (%esi), %eax
.else
    movzbl (%esi), %eax
.endif
.endif
    addl %eax, %edx
    nop
    nop
    decl %ecx
    jnz loop_body
    xorl %ebx, %ebx
    movl $1, %eax
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 32
arena:
    .long 0x8001ff80
