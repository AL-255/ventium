/* Near RET fetch-window corpus. Normal reset, paging, CALL/RET and stack RAM.
 * KIND=0: C3; KIND=1: C2 0008. OFFSET selects every byte of a 32-byte line.
 * RELOC=1 gives CS/DS/SS base 0x10000000. SS16 preserves nonzero high ESP.
 */
#ifndef KIND
#define KIND 0
#endif
#ifndef OFFSET
#define OFFSET 20
#endif
#ifndef RELOC
#define RELOC 0
#endif
#ifndef SS16
#define SS16 0
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
    movl $0x0000ffff,0x528
#if SS16
    movl $(0x00009200 | (RELOC << 28)),0x52c
#else
    movl $(0x00cf9200 | (RELOC << 28)),0x52c
#endif
    movw $0x2f,0x480
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
    .set p,0
    .rept 16
    movl $(0xf0063+p*4096),(0x123c0+p*4)
    .set p,p+1
    .endr
    movl $0x180063,0x1203c /* linear 0000f000: SS16 stack */
    movl $0x180063,0x1223c /* linear 0008f000: SS32 stack */
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
    movw %ax,%fs
    movw %ax,%gs
    movw $0x28,%ax
    movw %ax,%ss
#if SS16
    movl $0x5aaafff0,%esp
#else
    movl $0x0008fff0,%esp
#endif
    movl %esp,%ebp
    movl $8,%ecx
    .global call_loop, hot_ret, after_ret, pair_u, pair_v
call_loop:
#if KIND == 1
    pushl $0x12345678
    pushl $0x3456789a
#endif
    call hot_ret
after_ret:
    cmpl %ebp,%esp
    jne fail
    decl %ecx
    jnz call_loop
    jmp pair_u
    .balign 32,0x90
pair_u:
    movl $0x12345678,%ebx
pair_v:
    movl $0x23456789,%edx
    cmpl $0x12345678,%ebx
    jne fail
    cmpl $0x23456789,%edx
    jne fail
    movb $0x42,%al
    jmp exit
fail:
    movb $0x43,%al
exit:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    .balign 32,0x90
    .space OFFSET,0x90
hot_ret:
#if KIND == 0
    ret
#elif KIND == 1
    ret $8
#else
#error invalid KIND
#endif
    /* Deliberately not executed: catches accidental fall-through. */
    ud2
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
