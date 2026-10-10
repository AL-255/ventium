/* Ordinary reset and paging; one real 66 D1 clock, then legal register U/V.
 * No snapshots, injected registers, special PCs, or benchmark-specific RTL.
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
    movl $0x0008fff0,%esp
    movl $0x5aa58001,0x3000
    movl $0x3000,%esi
    movl $0x12348001,%eax
    movl $0x87654321,%ebx
    movl $0x43218001,%edx
    movl $0x56718001,%edi
    movl $16,%ecx
    jmp hot_u
    .balign 32,0x90
    .space OFFSET,0x90
    .global hot_u, hot_v, after_pair, loop_tail, exit_port
hot_u:
#if KIND == 0
    shrw $1,%ax
hot_v:
    movl $0x456789ab,%ebx
#elif KIND == 1
    cmpw %dx,%di
hot_v:
    jne fail
#elif KIND == 2
    addw $1,%ax
hot_v:
    movl $0x456789ab,%ebx
#elif KIND == 3
    addw $1,%ax
hot_v:
    addl %eax,%ebx /* real parent-register RAW, must not pair */
#elif KIND == 4
    movw $0xfef0,%sp
hot_v:
    movl $0x8fff0,%esp /* explicit SP/ESP WAW, never implicit-stack exception */
#elif KIND == 5
    shrw $1,%ax
hot_v:
    addw $1,%bx /* prefixed V excluded, must pay its own D1 */
#elif KIND == 6
    movw (%esi),%ax /* memory remains an ordinary reference instruction */
hot_v:
    addl %eax,%ebx
#elif KIND == 7
    .byte 0x66,0x66,0x83,0xc0,0x01 /* multiple prefixes: reference fallback */
hot_v:
    addl %eax,%ebx
#else
#error invalid KIND
#endif
after_pair:
    /* All compared states include the preserved word destination upper half. */
    nop
loop_tail:
    decl %ecx
    jnz hot_u
    movl %eax,%edx
    shrl $16,%edx
    cmpl $0x1234,%edx
    jne fail
    movb $0x42,%al
    jmp exit_port
fail:
    movb $0x43,%al
exit_port:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
