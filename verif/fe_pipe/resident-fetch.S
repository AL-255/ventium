/* General slow-fetch handoff, all line offsets, ordinary cold boot.
 * PUSHF/POPF are intentionally outside the fast integer dispatch subset.
 * The loop also requires an independent MOV/INC pair in UV mode.
 * Nonidentity stack mapping exercises the real paging/memory interface.
 */
#ifndef OFFSET
#define OFFSET 0
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
    movw %ax,%fs
    movw %ax,%gs
    movl $0x8fff0,%esp
    movl $0x12023,0x11000
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
    jmp paging_ready
paging_ready:
    movl $10,%ecx
    xorl %esi,%esi
    jmp hot_loop
    .balign 32
    .space OFFSET,0x90
    .global hot_loop,pop_site,pair_u,pair_v
hot_loop:
    pushfl
pop_site:
    popfl
pair_u:
    movl $0x12345678,%eax
pair_v:
    incl %esi
    decl %ecx
    jnz hot_loop
    cmpl $10,%esi
    jne fail
    cmpl $0x12345678,%eax
    jne fail
    cmpl $0x8fff0,%esp
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
