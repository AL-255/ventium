# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# General near-control-transfer witnesses, linked below 64 KiB for the
# operand-size-16 cases. No guest snapshots, fixed-target shortcuts, or score.
.ifndef CASE
.set CASE,0
.endif
.text
.globl _start
_start:
    movl $1000,%ecx
    movl $callee,%edi
    movl $callee,fnptr
    xorl %eax,%eax
    xorl %edx,%edx
.balign 32
.globl loop_body
loop_body:
.if CASE==0
    call callee
.elseif CASE==1
    call *%edi
.elseif CASE==2
    call *fnptr
.elseif CASE==3
    movl $jump_landing,%edi
    jmp *%edi
.elseif CASE==4
    movl $jump_landing,fnptr
    jmp *fnptr
.elseif CASE==5
    callw callee
.elseif CASE==6
    pushl %eax
    call callee
.elseif CASE==7
    pushw %ax
    callw callee
.elseif CASE==8
    xorl $1,%eax
    movb %al,callee+1
    call callee
    cmpl %eax,%edx
    jne failure
.elseif CASE==9
    # Both callees and the loop share an I-cache set but occupy three ways'
    # worth of tags. Returned-way identities must be checked after refill.
    call callee
    call conflict_callee
.elseif CASE==10
    call crossline_callee
.else
    .error "CASE must be 0..10"
.endif
.globl jump_landing
jump_landing:
    decl %ecx
    jnz loop_body
    xorl %ebx,%ebx
    movl $1,%eax
.globl exit_syscall
exit_syscall:
    int $0x80
failure:
    movl $99,%ebx
    movl $1,%eax
    int $0x80

.balign 4096
.globl callee
callee:
.if CASE==8
    movl $0,%edx
.else
    incl %edx
.endif
.if CASE==5
    retw
.elseif CASE==6
    ret $4
.elseif CASE==7
    retw $2
.else
    ret
.endif
.balign 4096
conflict_callee:
    incl %edx
    ret
.balign 32
.space 29,0x90
crossline_callee:
    movl $0x12345678,%edx
    ret
.data
.balign 4
fnptr:
    .long 0
