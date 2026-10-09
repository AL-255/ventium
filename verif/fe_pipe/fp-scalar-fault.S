/* Cold scalar FISTP/FSTP store precision, including second-page faults.
 * Eight ordinary calls warm the same instruction. The ninth faults before
 * any byte is stored or ST0 popped. The handler checks and repairs only the
 * page table, then the original instruction restarts and stores exact 1. */
#ifndef KIND
#define KIND 0
#endif
#ifndef SPLIT
#define SPLIT 0
#endif
#ifndef PRESENT
#define PRESENT 1
#endif
#if KIND == 0
#define WIDTH 4
#elif KIND == 1
#define WIDTH 8
#else
#define WIDTH 10
#endif
#if SPLIT
#define DEST 0x400fff
#else
#define DEST 0x401000
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
    movl $0xdeadbeef,0x14ffc
    movl $0xdeadbeef,0x15000
    movl $0xdeadbeef,0x15004
    movl $0xdeadbeef,0x15008
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
#if PRESENT
    movl $0x15001,0x13004
#else
    movl $0x15002,0x13004
#endif
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
    call do_store
    decl %ecx
    jnz warm
    movl $DEST,%ebx
    call do_store
    cmpl $1,0x2000
    jne fail
    cmpl $9,%edi
    jne fail
    fnstsw %ax
    testw $0x3800,%ax
    jnz fail
    movl $expected,%esi
    movl $WIDTH,%ecx
check:
    movb (%ebx),%al
    cmpb (%esi),%al
    jne fail
    incl %esi
    incl %ebx
    loop check
    movb $0x42,%al
    jmp exit
do_store:
    fld1
    fnstsw %ax
    jmp pair_u
    .balign 32,0x90
    .global pair_u,pair_v,hot_op,hot_after
pair_u:
    movl $0x12345678,%edx
pair_v:
    incl %edi
hot_op:
#if KIND == 0
    fistpl (%ebx)
#elif KIND == 1
    fstpl (%ebx)
#else
    fstpt (%ebx)
#endif
hot_after:
    ret
    .global pf_handler
pf_handler:
    cmpl $2+PRESENT,(%esp)
    jne fail
    cmpl $hot_op,4(%esp)
    jne fail
    movl %cr2,%eax
    cmpl $0x401000,%eax
    jne fail
    cmpl $0xdeadbeef,0x14ffc
    jne fail
    cmpl $0xdeadbeef,0x15000
    jne fail
    cmpl $0xdeadbeef,0x15004
    jne fail
    cmpl $0xdeadbeef,0x15008
    jne fail
    fnstsw %ax
    andl $0x3800,%eax
    cmpl $0x3800,%eax
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
expected:
#if KIND == 0
    .long 1
#elif KIND == 1
    .long 0,0x3ff00000
#else
    .long 0,0x80000000
    .word 0x3fff
#endif
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
