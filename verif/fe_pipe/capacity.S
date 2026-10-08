/* Nonidentity paged UV-fast working-set probe; not a gameplay benchmark.
 * Different cache-line offsets avoid manufacturing an L1 set-conflict test.
 * PAGES varies the number of hot data translations without any loop accesses
 * to the stack, page tables, or guest-specific addresses.
 */
#ifndef PAGES
#define PAGES 8
#endif
#define ROUNDS 10
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
    movw %ax,%fs
    movw %ax,%gs
    movl $0x90000,%esp
    movl $0x12023,0x11000
    movl $0x13023,0x11004
    .set p,0
    .rept 16
    movl $(0xf0063+p*4096),(0x123c0+p*4)
    .set p,p+1
    .endr
    .set p,0
    .rept PAGES
    movl $(0x200063+p*4096),(0x13000+p*4)
    movl $(p+1),(0x200000+p*4096+p*32)
    .set p,p+1
    .endr
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    andl $0x9fffffff,%eax
    orl $0x80000000,%eax
    movl %eax,%cr0
    jmp paging_ready
paging_ready:
    movl $0x400000,%ebx
    movl $ROUNDS,%ecx
    xorl %esi,%esi
    xorl %edi,%edi
    .balign 16
    .global hot_loop,first_load,first_independent
hot_loop:
first_load:
    movl (%ebx),%eax
first_independent:
    incl %esi
    addl %eax,%edi
    .set p,1
    .rept PAGES-1
    movl (p*4096+p*32)(%ebx),%eax
    incl %esi
    addl %eax,%edi
    .set p,p+1
    .endr
    decl %ecx
    jnz hot_loop
    cmpl $(ROUNDS*PAGES*(PAGES+1)/2),%edi
    jne fail
    cmpl $(ROUNDS*PAGES),%esi
    jne fail
    movb $0x42,%al
    jmp exit
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
