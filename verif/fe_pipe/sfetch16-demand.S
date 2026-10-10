/* Normal reset-vector, 16-bit real/protected/paged code, then a real U/V pair.
 * PREFIX=0..14, KIND=0 NOP / 1 MOV-immediate / 2 addr32+op32 SIB memory store.
 * OFFSET chooses a cache-line byte; PAGE_TAIL moves it to the last line/page.
 * No snapshot, injected architectural state, or bypass of actual execution.
 */
#ifndef MODE
#define MODE 0
#endif
#ifndef PREFIX
#define PREFIX 0
#endif
#ifndef KIND
#define KIND 0
#endif
#ifndef OFFSET
#define OFFSET 0
#endif
#ifndef PAGE_TAIL
#define PAGE_TAIL 0
#endif
#ifndef CACHE_ENABLED
#define CACHE_ENABLED 0
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
    movl $0x00cf9a00,0x50c /* 08: flat 32-bit code */
    movl $0x0000ffff,0x510
    movl $0x00cf9200,0x514 /* 10: flat 32-bit data */
    movl $0x0000ffff,0x518
    movl $0x00009a0f,0x51c /* 18: base f0000, 64KiB 16-bit code */
    movl $0x0000ffff,0x520
    movl $0x00009200,0x524 /* 20: base zero, 64KiB 16-bit data */
    movw $0x27,0x480
    movl $0x500,0x482
    lgdt 0x480
#if CACHE_ENABLED
    /* Model the measured gameplay's CR0.CD=NW=0, not reset-time uncached ROM. */
    movl %cr0,%eax
    andl $0x9fffffff,%eax
    movl %eax,%cr0
#endif
#if MODE == 1
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
    .byte 0xea
    .word pm16_setup-_start16
    .word 0x18
#elif MODE == 2
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long page_setup
    .word 8
#elif MODE != 0
#error invalid MODE
#endif
pm16_setup:
#if MODE != 0
    movw $0x20,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
#endif
    movw $16,%cx
    movw $0,%bx
    movw $0,%si
    movl $0,0x800
    jmp hot_instruction
after_hot:
#if KIND == 1
    cmpw $0x1234,%si
    jne fail16
#elif KIND == 2
    cmpl $0x12345678,0x800
    jne fail16
#endif
    incw %bx
    decw %cx
    jnz hot_instruction
    cmpw $16,%bx
    jne fail16
#if MODE == 0
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
#endif
    .byte 0x66,0xea
    .long finish32
    .word 8
fail16:
    movw $0xf4,%dx
    movb $0x43,%al
    outb %al,%dx
    hlt
#if PAGE_TAIL
    .balign 4096,0x90
    .space 4096-32,0x90
#else
    .balign 32,0x90
#endif
    .space OFFSET,0x90
    .global hot_instruction, hot_end
hot_instruction:
    .rept PREFIX
    .byte 0x3e /* DS override: repeatable, not an operand-size toggle */
    .endr
#if KIND == 0
    nop
#elif KIND == 1
    movw $0x1234,%si
#elif KIND == 2
    /* 67 66 C7 04 25 disp32 imm32, no GPR address dependency. */
    .byte 0x67,0x66,0xc7,0x04,0x25
    .long 0x800
    .long 0x12345678
#else
#error invalid KIND
#endif
hot_end:
    jmp after_hot
    .code32
    .section .text32,"ax"
page_setup:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x12023,0x11000
    movl $0x000063,0x12000
    movl $0x007063,0x1201c
    .set p,0
    .rept 16
    movl $(0xf0063+p*4096),(0x123c0+p*4)
    .set p,p+1
    .endr
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    andl $0x9fffffff,%eax
    orl $0x80000000,%eax
    movl %eax,%cr0
    .byte 0xea
    .long pm16_setup-_start16
    .word 0x18
finish32:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    jmp pair_u
    .balign 32,0x90
    .global pair_u, pair_v
pair_u:
    movl $0x12345678,%ebx
pair_v:
    movl $0x23456789,%edx
    cmpl $0x12345678,%ebx
    jne fail32
    cmpl $0x23456789,%edx
    jne fail32
    movb $0x42,%al
    jmp exit
fail32:
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
