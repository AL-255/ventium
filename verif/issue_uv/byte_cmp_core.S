/* Cold paged byte-CMP, real memory traffic and all arithmetic flags checked.
 * KIND 0 base; 1 base+disp8; 2 SIB/SS; 3 byte at last address of mapped page.
 * The following page remains absent: a widened architectural read must fail.
 */
#ifndef KIND
#define KIND 0
#endif
#ifndef OFFSET
#define OFFSET 0
#endif
#ifndef RELOC
#define RELOC 0
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
    movl $0x0000ffff,0x518
    movl $(0x00cf9a00 | (RELOC << 28)),0x51c
    movl $0x0000ffff,0x520
    movl $(0x00cf9200 | (RELOC << 28)),0x524
    movw $0x27,0x480
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
    movl $0x12023,0x11000
    movl $0x12023,0x11100
    movl $0x000063,0x12000
    movl $0x003063,0x1200c
#ifdef BC_FAULT
    movl $0x002063,0x12008
    movl $0x012063,0x12048
#endif
    .set p,0
    .rept 16
    movl $(0xf0063+p*4096),(0x123c0+p*4)
    .set p,p+1
    .endr
    movl $0x180063,0x1223c
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    andl $0x9fffffff,%eax
    orl $0x80000000,%eax
    movl %eax,%cr0
    .byte 0xea
    .long client
    .word 0x18
client:
    movw $0x20,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw %ax,%fs
    movw %ax,%gs
    movl $0x8fff0,%esp
#ifdef BC_FAULT
    movl $byte_pf,%eax
    movw %ax,0x2070
    movw $8,0x2072
    movw $0x8e00,0x2074
    shrl $16,%eax
    movw %ax,0x2076
    movw $0x7ff,0x2408
    movl $0x2000,0x240a
    movl $0,0x2400
    lidt 0x2408
#endif
    .set p,0
    .rept 24
    movl $0x11223344,(0x3000+p*4)
    .set p,p+1
    .endr
    movl $0x3000,%esi
    movl $0x3fff,%edi
    movl $0x78,%edx
    movl $16,%ecx
#if KIND == 1
    movl $0x3003,%ebx
#elif KIND == 2
    movl $3,%ebx
#endif
    movl (%esi),%eax
    movl (%esp),%eax
    jmp hot_u
    .balign 32,0x90
    .space OFFSET,0x90
    .global hot_u,hot_load,second_store,pair_v,exit_port
hot_u:
#if KIND == 0
    movb %dl,(%esi)
#elif KIND == 1
    movb %dl,-3(%ebx)
#elif KIND == 2
    movb %dl,(%esp,%ebx,1)
#else
    movb %dl,(%edi)
#endif
second_store:
#ifdef BC_FAULT
    cmpl $16,%ecx
    jne pf_prepared
    movl $0,0x1200c
    movl %cr3,%eax
    movl %eax,%cr3
pf_prepared:
    stc
    pushfl
    popl %eax
    movl %eax,0x2404
#endif
hot_load:
#if KIND == 0
    cmpb $0x80,(%esi)
#elif KIND == 1
    cmpb $0x80,-3(%ebx)
#elif KIND == 2
    cmpb $0x80,(%esp,%ebx,1)
#else
    cmpb $0x80,(%edi)
#endif
    pushfl
    popl %ebp
    cmpb $0x80,%dl
    pushfl
    popl %eax
    andl $0x8d5,%eax
    andl $0x8d5,%ebp
    cmpl %eax,%ebp
    jne fail
    incl %edx
    decl %ecx
    jz done
    jmp hot_u
done:
#ifdef BC_FAULT
    cmpl $1,0x2400
    jne fail
#endif
    jmp verify_pair
    .balign 32,0x90
verify_pair:
    movl $0x12345678,%esi
pair_v:
    movl $0x76543210,%edi
    movb $0x42,%al
    jmp exit_port
fail:
    movb $0x43,%al
exit_port:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
#ifdef BC_FAULT
byte_pf:
    pushal
    cmpl $0,32(%esp)
    jne fail
    cmpl $hot_load,36(%esp)
    jne fail
    movl 44(%esp),%eax
    andl $0x8d5,%eax
    movl 0x2404,%ebp
    andl $0x8d5,%ebp
    cmpl %eax,%ebp
    jne fail
    movl %cr2,%eax
#if KIND == 3
    cmpl $(0x3fff+RELOC*0x10000000),%eax
#else
    cmpl $(0x3000+RELOC*0x10000000),%eax
#endif
    jne fail
    incl 0x2400
    cmpl $1,0x2400
    jne fail
    movl $0x3063,0x1200c
    movl %cr3,%eax
    movl %eax,%cr3
    popal
    addl $4,%esp
    iret
#endif
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
