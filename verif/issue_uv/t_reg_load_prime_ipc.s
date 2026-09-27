# A register-only packet followed by an independent resident D-cache load.
# The two INC instructions depend on one another, leaving the second as its
# own U packet; its idle D-cache lookup slot may capture the following MOV.
# XOR alternates two resident cache lines so same-line window reuse cannot
# manufacture the speedup. It precedes the priming packet, so the load's ESI
# address is not dependent on the priming packet.
# Six instructions per loop for run-load-issue-ipc.sh's fixed-work checker.
.ifndef ITERATIONS
.set ITERATIONS, 1000
.endif
.text
.globl _start
_start:
    movl $arena, %esi
    movl $ITERATIONS, %ecx
    xorl %eax, %eax
    xorl %ebx, %ebx
    jmp loop_body
.balign 32
.globl loop_body
loop_body:
    xorl $32, %esi
    incl %ebx
    incl %ebx
    movl (%esi), %eax
    decl %ecx
    jnz loop_body
.globl loop_end
loop_end:
.globl exit_syscall
exit_syscall:
    movl $1, %eax
    xorl %ebx, %ebx
    int $0x80
.data
.balign 32
arena:
    .long 0x12345678
    .space 28
    .long 0x87654321
.section .note.GNU-stack,"",@progbits
