/* Cold read-retirement hint safety. Eight warm calls prove the optimization
 * fires before PF retry, split-page PF, TF retirement or CPU-store SMC.
 * Only guest instructions create state. Fault handlers never skip an access. */
#ifndef KIND
#define KIND 0
#endif
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw %ax,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw $0x7000,%sp
    movl $0,0x500
    movl $0,0x504
    movl $0xffff,0x508
    movl $0x00cf9a00,0x50c
    movl $0xffff,0x510
    movl $0x00cf9200,0x514
    movw $0x17,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long pm32
    .word 8
    .code32
    .section .text32,"ax"
pm32:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x90000,%esp
    movl $pf_handler,%ebx
    movl $0x1070,%edi
    call gate
    movl $db_handler,%ebx
    movl $0x1008,%edi
    call gate
    movw $0x7ff,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $0,0x2000
    movl $0,0x2004
    movl $hot_template,%esi
    movl $0x4000,%edi
    movl $(hot_end-hot_template),%ecx
    rep movsb
    movl $3,0x8100
    movl $7,0x8120
    movl $11,0x8140
    movl $9,0x9040
#if KIND == 1
    movl $5,0x8fff
#else
    movl $5,0x9000
#endif
    movl $0x12000,%edi
    movl $0x63,%eax
    movl $256,%ecx
1:  movl %eax,(%edi)
    addl $0x1000,%eax
    addl $4,%edi
    loop 1b
    movl $0x12003,0x11000
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    andl $0x9fffffff,%eax
    orl $0x80010000,%eax
    movl %eax,%cr0
    movl $8,%ebp
    movl $0x4000,%ebx
warm:
    xorl %edi,%edi
    call *%ebx
    cmpl $26,%edi
    jne fail
    decl %ebp
    jnz warm
    jmp pair_u
    .balign 32,0x90
    .global pair_u,pair_v
pair_u:
    movl $0x23456789,%eax
pair_v:
    movl $0x3456789a,%edx
#if KIND < 2
    movl $0x9062,0x12024
    invlpg (0x9000)
#elif KIND == 3
    /* Change the actual displacement in the already-executed RAM code. */
    movl $0x9040,(0x4000+hot_second-hot_template+2)
#endif
    xorl %edi,%edi
#if KIND == 2
    pushl $after_final
    pushl $0x102
    pushl $8
    pushl $0x4000
    iretl
#else
    call *%ebx
#endif
after_final:
#if KIND == 3
    cmpl $30,%edi
#else
    cmpl $26,%edi
#endif
    jne fail
#if KIND < 2
    cmpl $1,0x2000
#else
    cmpl $0,0x2000
#endif
    jne fail
#if KIND == 2
    cmpl $1,0x2004
#else
    cmpl $0,0x2004
#endif
    jne fail
    movb $0x42,%al
    jmp exit
gate:
    movl %ebx,%eax
    andl $0xffff,%eax
    orl $0x80000,%eax
    movl %eax,(%edi)
    movl %ebx,%eax
    andl $0xffff0000,%eax
    orl $0x8e00,%eax
    movl %eax,4(%edi)
    ret
    .global pf_handler,db_handler
pf_handler:
    incl 0x2000
    cmpl $1,0x2000
    jne fail
    cmpl $0,(%esp)
    jne fail
    cmpl $(0x4000+hot_second-hot_template),4(%esp)
    jne fail
    cmpl $3,%edi
    jne fail
    movl %cr2,%eax
    cmpl $0x9000,%eax
    jne fail
    movl $0x9063,0x12024
    invlpg (0x9000)
    addl $4,%esp
    iretl
db_handler:
    incl 0x2004
    cmpl $1,0x2004
    jne fail
    cmpl $(0x4000+hot_second-hot_template),(%esp)
    jne fail
    cmpl $3,%edi
    jne fail
    testl $0x100,8(%esp)
    jz fail
    movl %dr6,%eax
    testl $0x4000,%eax
    jz fail
    andl $~0x100,8(%esp)
    iretl
fail:
    movb $0x43,%al
exit:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    .balign 32,0x90
    .global hot_template,hot_second,hot_end
hot_template:
    addl 0x8100,%edi
hot_second:
#if KIND == 1
    addl 0x8fff,%edi
#else
    addl 0x9000,%edi
#endif
    addl 0x8120,%edi
    addl 0x8140,%edi
    ret
hot_end:
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
