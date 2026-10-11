/* Cold paged/relocated U arithmetic and forwarded Jcc cases.
 * General processor coverage; no saved state, injected cache or workload hacks.
 */
#ifndef CASE
#define CASE 0
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
    movl $0x8fff0,%esp
    movl $0x3000,%esi
    movl $1,(%esi)
    movl $8,%ecx
loop_head:
    movl (%esi),%ebx
#if CASE == 0
    movl $0xa55a7f01,%eax
#elif CASE == 1 || CASE == 6
    movl $0xa55affff,%eax
    stc
#elif CASE == 2
    movl $0xfffffffe,%eax
    stc
#elif CASE == 3
    movl $0xa55a0000,%eax
    stc
#elif CASE == 4
    movl $0x80000000,%eax
#elif CASE == 5
    movl $0xa55a0080,%eax
#elif CASE == 7
    movl $0xa55a0001,%eax
    clc
#elif CASE == 8
    movl $0xa55a8000,%eax
#elif CASE == 9 || CASE == 14 || CASE == 15
    movl $0xffffffff,%eax
    clc
#elif CASE == 10
    movl $0xa55a0001,%eax
#elif CASE == 11
    movl $0xa55a5aa5,%eax
#elif CASE == 12
    movl $0xa55a8001,%eax
#elif CASE == 13
    movl $0,%eax
    stc
#else
#error unknown case
#endif
    jmp alu_subject
    .balign 32,0x90
    .space OFFSET,0x90
    .global alu_subject,alu_branch,alu_taken,fail,exit_port
alu_subject:
#if CASE == 0
    addb $1,%ah
#elif CASE == 1
    addw $1,%ax
#elif CASE == 2
    adcl $1,%eax
#elif CASE == 3
    sbbw $0,%ax
#elif CASE == 4
    subl $1,%eax
#elif CASE == 5
    cmpb $1,%al
#elif CASE == 6
    incw %ax
#elif CASE == 7
    decb %ah
#elif CASE == 8
    negw %ax
#elif CASE == 9
    andl $0,%eax
#elif CASE == 10
    orb $0x80,%ah
#elif CASE == 11
    xorw %ax,%ax
#elif CASE == 12
    testb $0x80,%ah
#elif CASE == 13
    movl $0xa55a81ff,%eax
#elif CASE == 14
    notl %eax
#else
    addl (%esi),%eax
#endif
alu_branch:
#if CASE == 0 || CASE == 4 || CASE == 5 || CASE == 8
    jo alu_taken
#elif CASE == 1 || CASE == 2 || CASE == 3 || CASE == 6 || CASE == 13
    jc alu_taken
#elif CASE == 7 || CASE == 14
    jnc alu_taken
#elif CASE == 10 || CASE == 12
    js alu_taken
#else
    jz alu_taken
#endif
fail:
    movb $0x43,%al
    jmp exit_port
alu_taken:
    decl %ecx
    jnz loop_head
    movb $0x42,%al
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
