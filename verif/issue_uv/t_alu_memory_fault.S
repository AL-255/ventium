/* Checked dword source crossing a nonpresent second page. No saved state. */
.ifndef ALU_OP
.set ALU_OP,5
.endif
.ifndef INITIAL_CF
.set INITIAL_CF,1
.endif
.set PBYTE_PAGE_SETUP,1
.set PBYTE_PAGE_PROBE,1
.macro pbyte_page_setup
    .irp page,0,2,8,0x11,0x12,0x13,0x8f
    movl $(\page*4096+3),0x12000+\page*4
    .endr
    movl $alu_pf,%eax
    movw %ax,0x2070
    movw $8,0x2072
    movw $0x8e00,0x2074
    shrl $16,%eax
    movw %ax,0x2076
    movw $0x7ff,0x2080
    movl $0x2000,0x2082
    movl $0,0x2100
.endm
.macro pbyte_page_probe
    movl %cr0,%eax
    andl $0x9fffffff,%eax
.ifdef FP_OVERLAP
    andl $0xfffffff3,%eax        /* EM/TS clear; leave paging/PE intact */
.endif
    movl %eax,%cr0
    lidt 0x2080
    movl $alu_image,%esi
    movl $0x8000,%edi
    movl $alu_image_end-alu_image,%ecx
    rep movsb
    movl $0x80000001,0x404fff
    movl $0,0x13014
    movl %cr3,%eax
    movl %eax,%cr3
    movl $0x404fff,%esi
    movl $0x1234abcd,%ecx
.ifdef MEMORY_CHAIN
    movl $0x7fffffff,0x2108
    movl $0x2108,%edi
.endif
    jmp 0x8000
alu_warmed:
.ifdef MEMORY_CHAIN
    # Prime the older read's line, then replace the registered window with
    # another resident line so the older load owns a real delayed packet.
    movl (%edi),%edx
    movl 0x11000,%edx
.endif
.ifdef FP_OVERLAP
    /* Warm only the present source page, never the absent second page. */
    movl 0x404ffc,%edx
    fninit
    fld1
    fld1
.endif
    xorl %eax,%eax
.if INITIAL_CF
    stc
.else
    clc
.endif
    pushfl
    popl 0x2104
    movl $0x7fffffff,%eax
.ifdef FP_OVERLAP
    /* Enter the relocated FDIV immediately before the source. A jump AFTER
     * FDIV would drain it under the current branch policy and miss the race. */
    jmp 0x8011
.else
.ifdef MEMORY_CHAIN
    jmp 0x8011
.else
    jmp alu_source
.endif
.endif
alu_return:
.ifdef FP_OVERLAP
    fwait
.endif
.if ALU_OP==0
    cmpl $0,%eax
.elseif ALU_OP==1
    cmpl $0xffffffff,%eax
.elseif ALU_OP==2
    cmpl $INITIAL_CF,%eax
.elseif ALU_OP==3
    cmpl $(0xfffffffe-INITIAL_CF),%eax
.elseif ALU_OP==4
    cmpl $1,%eax
.elseif ALU_OP==5
    cmpl $0xfffffffe,%eax
.elseif ALU_OP==6
    cmpl $0xfffffffe,%eax
.else
.error "ALU_OP must be 0..6"
.endif
    jne alu_fail
    cmpl $1,0x2100
    jne alu_fail
    movl $0xa1fa0001,%edi
    jmp alu_done
alu_pf:
    pushal
    cmpl $0,32(%esp)
    jne alu_fail
    cmpl $alu_source,36(%esp)
    jne alu_fail
    cmpl $0x7fffffff,28(%esp)
    jne alu_fail
    cmpl $0x1234abcd,24(%esp)
    jne alu_fail
    movl 44(%esp),%eax
    andl $0x8d5,%eax
    movl 0x2104,%edx
    andl $0x8d5,%edx
    cmpl %edx,%eax
    jne alu_fail
    movl %cr2,%eax
    cmpl $0x405000,%eax
    jne alu_fail
    incl 0x2100
    cmpl $1,0x2100
    jne alu_fail
    movl $0x802003,0x13014
    movl %cr3,%eax
    movl %eax,%cr3
    popal
    addl $4,%esp
    iret
alu_fail:
    movl $0x43,%eax
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    jmp alu_fail
.balign 32
alu_image:
    .byte 0xe9
    .long alu_warmed-0x8005
    .byte 0xb8,0,0,0,0
    .byte 0xb9,0,0,0,0
.ifdef FP_OVERLAP
    .byte 0x90,0x90,0xd8,0xf1  /* padding, FDIV ST0,ST1 at 0x8011 */
.else
.ifdef MEMORY_CHAIN
    .byte 0x90,0x90,0x8b,0x07  /* older MOV EAX,[EDI] at 0x8011 */
.else
    .byte 0x83,0xc0,0
    nop
.endif
.endif
    .global alu_source
    .set alu_source,0x8013
    .byte (3+8*ALU_OP),0x06
    .byte 0xe9
    .long alu_return-0x801a
alu_image_end:
alu_done:
.endm
.include "../ppage/ppage.S"
