# Three hot code lines and two hot data lines all map to D-cache set zero.
# The I-cache has two ways, so cycling through three code blocks forces an
# instruction fill each iteration. Those fills must not evict both data ways.
.ifndef ITERATIONS
.set ITERATIONS, 1000
.endif
.text
.globl _start
_start:
    movl $arena, %esi
    movl $ITERATIONS, %ecx
    xorl %eax, %eax
    xorl %edx, %edx
    xorl %ebx, %ebx
    jmp loop_body
.balign 4096
.globl loop_body
loop_body:
    movl (%esi), %eax
    movl 4096(%esi), %edx
    jmp code_b
.balign 4096
.globl code_b
code_b:
    addl %edx, %eax
    jmp code_c
.balign 4096
.globl code_c
code_c:
    incl %ebx
    decl %ecx
    jnz loop_body
.globl loop_end
loop_end:
    movl $1, %eax
    xorl %ebx, %ebx
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 4096
.globl arena
arena:
    .long 0x10203040
    .space 4092
    .long 0x50607080
.section .note.GNU-stack,"",@progbits
