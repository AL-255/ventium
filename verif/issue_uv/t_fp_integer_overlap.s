# Same work, two schedules: FWAIT before integers (serial) or after (overlap).
# FP_OP: 0 ADD, 1 MUL, 2 DIV, 3 SQRT. INT_KIND: pairs, memory, carry chain,
# or a sole direct branch immediately after the FP command (3 = JMP,
# 4 = taken JNZ, 5 = not-taken JZ).
.text
.globl _start, loop_body, fp_site, integer_start, integer_end, pass_exit
_start:
    fninit
    fld1
    fld1
    xorl %eax,%eax
    xorl %ebx,%ebx
    movl $64,%ecx
    movl $source,%esi
.balign 32
loop_body:
.if INT_KIND==4 || INT_KIND==5
    # ECX is nonzero on every body visit.  x87 arithmetic must leave the
    # integer ZF from this TEST untouched for both conditional directions.
    testl %ecx,%ecx
.endif
fp_site:
.if FP_OP==0
    fadd %st(1),%st
.elseif FP_OP==1
    fmul %st(1),%st
.elseif FP_OP==2
    fdiv %st(1),%st
.elseif FP_OP==3
    fsqrt
.else
.error "bad FP_OP"
.endif
.if SERIAL
    fwait
.elseif INT_KIND<3
    nop
.endif
integer_start:
.if INT_KIND>=3
    # No preceding NOP: the branch must be the U owner, not a V partner of
    # an integer instruction that was already permitted under the FP hold.
.if INT_KIND==3
    jmp 1f
.elseif INT_KIND==4
    jnz 1f
.elseif INT_KIND==5
    jz 1f
.endif
integer_end:
.if INT_KIND!=5
    ud2
.endif
1:
    addl $1,%eax
.else
.rept 4
.if INT_KIND==0
    addl $1,%eax
    addl $2,%ebx
.elseif INT_KIND==1
    movl (%esi),%edx
    addl %edx,%eax
    movl %eax,sink
    addl $2,%ebx
.elseif INT_KIND==2
    addl $0x40000001,%eax
    adcl $0,%ebx
.else
.error "bad INT_KIND"
.endif
.endr
integer_end:
.endif
.if !SERIAL
    fwait
.elseif INT_KIND<3
    nop
.endif
    decl %ecx
    jnz loop_body
    fstpl result
    fstp %st(0)
    movl $1,%eax
    xorl %ebx,%ebx
pass_exit:
    int $0x80
.data
.balign 8
source: .long 7
sink: .long 0
result: .double 0
.section .note.GNU-stack,"",@progbits
