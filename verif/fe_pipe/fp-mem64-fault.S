/* Fully acquired m64 queue: ordinary warm calls, then absent first/second
 * operand page. #PF must drain the older divide, preserve its metadata and
 * leave the younger source unexecuted. The guest repairs its PTE and retries. */
#ifndef KIND
#define KIND 0
#endif
#ifndef SPLIT
#define SPLIT 0
#endif
#if SPLIT
#define SOURCE 0x400ffc
#else
#define SOURCE 0x401000
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
    movl $0x0000ffff,0x508
    movl $0x00cf9a00,0x50c
    movl $0x0000ffff,0x510
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
    movl $pf_handler,%eax
    movw %ax,0x1070
    movw $8,0x1072
    movw $0x8e00,0x1074
    shrl $16,%eax
    movw %ax,0x1076
    movw $0x7ff,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $0,0x2000
    movl $0x40400000,0x3060
    movl $0x40c00000,0x3064
#if KIND == 2
#define LO -7
#define HI -1
#else
#define LO 0
#define HI 0x40100000
#endif
    movl $LO,0x14100
    movl $HI,0x14104
#if SPLIT
    movl $LO,0x14ffc
    movl $HI,0x15000
#else
    movl $LO,0x15000
    movl $HI,0x15004
#endif
    movl $0x12000,%edi
    movl $3,%eax
    movl $22,%ecx
1:  movl %eax,(%edi)
    addl $0x1000,%eax
    addl $4,%edi
    loop 1b
    movl $0x8f003,0x1223c
    movl $0x90003,0x12240
    movl $0x123c0,%edi
    movl $0xf0003,%eax
    movl $16,%ecx
1:  movl %eax,(%edi)
    addl $0x1000,%eax
    addl $4,%edi
    loop 1b
    movl $0x14003,0x13000
    movl $0x15002,0x13004
    movl $0x12003,0x11000
    movl $0x13003,0x11004
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    andl $0x9fffffff,%eax
    orl $0x80010000,%eax
    movl %eax,%cr0
    fninit
    xorl %edi,%edi
    movl $8,%ecx
    movl $0x400100,%ebx
warm:
    call do_op
    decl %ecx
    jnz warm
    movl $SOURCE,%ebx
    call do_op
    cmpl $1,0x2000
    jne fail
    cmpl $9,%edi
    jne fail
    fnstsw %ax
    testw $0x3800,%ax
    jnz fail
    movb $0x42,%al
    jmp exit
do_op:
    flds 0x3060
    flds 0x3064
    .global older_op,source_op,integer_begin,integer_end,pair_u,pair_v
older_op:
    fdiv %st(1),%st
source_op:
#if KIND == 0
    faddl (%ebx)
#elif KIND == 1
    fldl (%ebx)
#else
    fildq (%ebx)
#endif
integer_begin:
    incl %edi
integer_end:
    fwait
    fnstenv 0x3040
    cmpl $source_op,0x304c
    jne fail
    cmpl %ebx,0x3054
    jne fail
    fldenv 0x3040
    fstpl 0x3020
    cmpl $0,0x3020
    jne fail
#if KIND == 0
    cmpl $0x40180000,0x3024
#elif KIND == 1
    cmpl $0x40100000,0x3024
#else
    cmpl $0xc01c0000,0x3024
#endif
    jne fail
#if KIND != 0
    fstp %st(0)
#endif
    fstp %st(0)
    jmp pair_u
    .balign 32,0x90
pair_u:
    movl $0x12345678,%edx
pair_v:
    movl $0x23456789,%esi
    ret
    .global pf_handler
pf_handler:
    cmpl $0,(%esp)
    jne fail
    cmpl $source_op,4(%esp)
    jne fail
    movl %cr2,%eax
    cmpl $0x401000,%eax
    jne fail
    cmpl $8,%edi
    jne fail
    fnstenv 0x3040
    cmpl $older_op,0x304c
    jne fail
    cmpl $0x3064,0x3054
    jne fail
    cmpw $8,0x3050
    jne fail
    cmpw $16,0x3058
    jne fail
    fnstsw %ax
    andl $0x3800,%eax
    cmpl $0x3000,%eax
    jne fail
    fstl 0x3030
    fwait
    cmpl $0,0x3030
    jne fail
    cmpl $0x40000000,0x3034
    jne fail
    incl 0x2000
    movl $0x15003,0x13004
    movl %cr3,%eax
    movl %eax,%cr3
    addl $4,%esp
    iretl
fail:
    movb $0x43,%al
exit:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
