/* Resolved near-control targets, ordinary cold paged system execution. */
#ifndef KIND
#define KIND 0
#endif
#ifndef RELOC
#define RELOC 0
#endif
#ifndef OFFSET
#define OFFSET 17
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
    movl $callee,%edi
    movl $callee,0x8f100
    xorl %edx,%edx
    xorl %eax,%eax
    movl $16,%ecx
    jmp hot_loop
    .balign 4096,0x90
    .space OFFSET,0x90
    .global hot_loop,hot_end,pair_u,pair_v
hot_loop:
#if KIND == 0
    call callee
#elif KIND == 1
    call *%edi
#elif KIND == 2
    call *0x8f100
#elif KIND == 3
    movl $jump_landing,%edi
    jmp *%edi
#elif KIND == 4
    movl $jump_landing,0x8f100
    jmp *0x8f100
#elif KIND == 5
    pushl %eax
    call callee
#elif KIND == 6
    /* Normal CPU stores replace the target MOV immediate on every visit. */
    movb $0xba,0x8f400
    movl %ecx,0x8f401
    movb $0xc3,0x8f405
    movl $0x8f400,%edi
    call *%edi
    cmpl %ecx,%edx
    jne fail
#elif KIND == 7
    call callee
    call conflict_callee
#elif KIND == 8
    call crossline_callee
#else
#error unsupported KIND
#endif
jump_landing:
#if KIND == 3 || KIND == 4
    incl %edx
#endif
hot_end:
    decl %ecx
    jnz hot_loop
#if KIND == 6
    cmpl $1,%edx
#elif KIND == 7
    cmpl $32,%edx
#elif KIND == 8
    cmpl $0x12345678,%edx
#else
    cmpl $16,%edx
#endif
    jne fail
    cmpl $0x8fff0,%esp
    jne fail
    movl $8,%ecx
    jmp pair_u
    .balign 32,0x90
pair_u:
    movl $0x23456789,%ebx
pair_v:
    movl $0x3456789a,%edx
    decl %ecx
    jnz pair_u
    cmpl $0x23456789,%ebx
    jne fail
    cmpl $0x3456789a,%edx
    jne fail
    movb $0x42,%al
    jmp exit
fail:
    movb $0x43,%al
exit:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    .balign 4096,0x90
callee:
    incl %edx
#if KIND == 5
    ret $4
#else
    ret
#endif
    .balign 4096,0x90
conflict_callee:
    incl %edx
    ret
    .balign 32,0x90
    .space 29,0x90
crossline_callee:
    movl $0x12345678,%edx
    ret
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
