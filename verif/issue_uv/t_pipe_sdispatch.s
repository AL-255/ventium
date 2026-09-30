// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Six retired instructions per iteration. Use the existing differential
// load-issue runner with RAW_MEMORY=1; no guest patch or saved state is used.
.text
.globl _start
_start:
    movl $1000, %ecx
    movl $0x12348001, %eax
    movl $0x76543210, %ebx
    movl $arena, %esi
    movl $arena, %edi
    movl $1, %ebp
    jmp loop_body
.balign 32
.ifdef BYTE_CONSUMER
.ifdef BYTE_HIGH
    .space 31, 0x90
.endif
.endif
.globl loop_body
loop_body:
.if COMPARE_CONSUMER
    // ASCII adjustment is encoded as K_ALU but is not a one-clock operation.
    // It must not be admitted by the ordinary integer-ALU shortcut.
    aad $10
.else
.ifdef BYTE_CONSUMER
.ifdef BYTE_HIGH
    // A prefixed instruction straddles the I-cache line. The reference
    // handoff must obtain its bytes from two independently tagged buffers.
    addw $7, %ax
.else
    setl %ah
.endif
.else
.ifdef BYTE_HIGH
.ifdef COUNT_UP
    // CL shifts retain their four-clock P54 execution policy.
    shlb %cl, %ah
.else
    rorb $1, %ah
.endif
.else
.ifdef DEPENDENT
    // Two ordinary prefixes must not use the one-prefix direct admission.
    .byte 0x2e
    addw $7, %ax
.else
    addw $7, %ax
.endif
.endif
.endif
.endif
    movl %esi, %esi
    testl %ebp, %ebp
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
    .long 0x01234567
