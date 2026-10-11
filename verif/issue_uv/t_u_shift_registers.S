/* Cold paged/relocated execution: register shifts, forwarded Jcc, memory ALU.
 * The subject is reached independently, never injected via a saved state.
 * CASE 7 is the ISA-required slow RCR control, not a fast-path acceptance case.
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
    movl $0xa55a4001,%eax
#elif CASE == 1
    movl $0xa55a4000,%eax
#elif CASE == 2
    movl $0,%eax
    testl %ebx,%ebx
#elif CASE == 3
    movl $0x81a57f01,%eax
    stc
#elif CASE == 4 || CASE == 5 || CASE == 7
    movl $1,%eax
    clc
#elif CASE == 6
    movl $0xffffffff,%eax
#else
#error unknown case
#endif
    jmp shift_subject
    .balign 32,0x90
    .space OFFSET,0x90
    .global shift_subject,shift_branch,shift_taken,fail,exit_port
shift_subject:
#if CASE == 0
    shlb $1,%ah
#elif CASE == 1
    shlw $1,%ax
#elif CASE == 2
    .byte 0xc1,0xc8,1       /* ROR EAX,imm8, not D1 ROR. */
#elif CASE == 3
    shll $0,%eax
#elif CASE == 4
    shll $31,%eax
#elif CASE == 5
    shrw $1,%ax
#elif CASE == 6
    addl (%esi),%eax
#else
    rcrl $1,%eax
#endif
shift_branch:
#if CASE == 0 || CASE == 4
    js shift_taken
#elif CASE == 1
    jo shift_taken
#elif CASE == 2
    jnz shift_taken
#elif CASE == 3 || CASE == 5 || CASE == 7
    jc shift_taken
#else
    jz shift_taken
#endif
fail:
    movb $0x43,%al
    jmp exit_port
shift_taken:
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
