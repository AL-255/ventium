# Shared checked-memory ALU regression. No saved state or guest-specific code.
.ifndef OP
.set OP, 5
.endif
.ifndef INITIAL_CF
.set INITIAL_CF, 0
.endif
.text
.globl _start
_start:
    movl %esp,%ebp
    pushl $0x80000001
    xorl %edx,%edx
    movl $arena,%esi
    movl $arena+4,%edi
    movl $1,%ebx
    movl $64,%ecx
    jmp loop_body
.macro carry
.if INITIAL_CF
    stc
.else
    clc
.endif
.endm
.macro exercise op
    movl $0x7fffffff,%eax
    carry
    \op (%esi),%eax
    seto %dl
    setc %dh
    movb %ah,%dl
    carry
    \op -4(%edi),%eax
    adcl $0,%edx
    carry
    \op arena+4,%eax
    setc %dl
    carry
    \op 256(%esi),%eax
    setz %dh
    carry
    \op 4(%esi,%ebx,4),%eax
    setc %dl
    carry
    \op 256(%esi,%ebx,4),%eax
    seto %dh
    carry
    \op arena(,%ebx,4),%eax
    setc %dl
    # ESP base selects SS; EBP remains the preserved original stack pointer.
    carry
    \op (%esp),%eax
    seto %dh
    # Misaligned line-crossing and page-crossing operands.
    carry
    \op arena+31,%eax
    setc %dl
    carry
    \op arena+4095,%eax
    seto %dh
    # Independent U/V follower must retain its own result and flags.
    carry
    \op (%esi),%eax
    movl $0x10203040,%edx
.endm
.balign 32
.globl loop_body
loop_body:
.if OP==0
    exercise addl
.elseif OP==1
    exercise orl
.elseif OP==2
    exercise adcl
.elseif OP==3
    exercise sbbl
.elseif OP==4
    exercise andl
.elseif OP==5
    exercise subl
.elseif OP==6
    exercise xorl
.else
.error "OP must be 0..6"
.endif
    decl %ecx
    jnz loop_body
.globl loop_end
loop_end:
    movl %ebp,%esp
    movl $1,%eax
    xorl %ebx,%ebx
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 4096
arena:
    .long 0x80000001,0xffffffff,0x00000001,0
    .fill 1025,4,0x7f01ff80
.section .note.GNU-stack,"",@progbits
