/* Cold protected-mode reference-dispatch benchmark. No snapshots/guest hooks.
 * KIND 0: word ALU; 1: signed byte load; 2: IMUL; 3: excluded variable shift.
 * RELOC selects equal CS/DS/SS/ES bases at 0 or 0x10000000.
 */
#ifndef KIND
#define KIND 0
#endif
#ifndef RELOC
#define RELOC 0
#endif
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
    movl $0x000063,0x12000 /* GDT page */
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
    movl $0x8f100,%ebp
    movb $0x80,(%ebp)
    movl $10,%ecx
    movl $3,%edi
    xorl %esi,%esi
#if KIND == 0
    movl $0x12340003,%eax
#else
    movl $1,%eax
#endif
    jmp hot_loop
    .balign 32
    .space OFFSET,0x90
    .global hot_loop,pair_u,pair_v
hot_loop:
#if KIND == 0
    addw $7,%ax
#elif KIND == 1
    movsbl (%ebp),%eax
#elif KIND == 2
    imull %edi,%eax
#elif KIND == 3
    shll %cl,%eax
#else
#error unsupported KIND
#endif
pair_u:
    movl $0x12345678,%ebx
pair_v:
    incl %esi
    decl %ecx
    jnz hot_loop
    cmpl $10,%esi
    jne fail
    cmpl $0x12345678,%ebx
    jne fail
    cmpl $0x8fff0,%esp
    jne fail
#if KIND == 0
    cmpl $0x12340049,%eax
#elif KIND == 1
    cmpl $0xffffff80,%eax
#elif KIND == 2
    cmpl $59049,%eax
#else
    cmpl $0,%eax
#endif
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
