/* Fixed 256-round scalar-memory workload. Initial queue/fill transients are
 * retained in complete-program timing; a separate long steady window starts
 * after 32 completed rounds. No delay or mutation in the measured loop. */
#ifndef KIND
#define KIND 0
#endif
#ifndef RELOC
#define RELOC 0
#endif
#ifndef OFFSET
#define OFFSET 17
#endif
#ifndef CONTROL_WORD
#define CONTROL_WORD 0x37f
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
    movl $0x8f100,%ebp
    xorl %edi,%edi
    movl $0,(%ebp)
    movl $0,128(%ebp)
#if KIND == 9 || KIND == 16
    movl $0,132(%ebp)
#endif
#if KIND == 10 || KIND == 13 || KIND == 14
    movl $1,128(%ebp)
#endif
    movw $0x037f,0x8f300
    fninit
#ifdef APPLY_CONTROL_WORD
    movw $CONTROL_WORD,0x8f300
    fldcw 0x8f300
#endif
    fld1
    movl $256,%ecx
    jmp hot_loop
    .balign 32,0x90
    .space OFFSET,0x90
    .global hot_loop,hot_end,pair_u,pair_v
hot_loop:
#if KIND == 0
    fnstcw 0x8f200
#elif KIND == 1
    fldcw 0x8f300
#elif KIND == 2
    fistl (%ebp)
#elif KIND == 3
    fsts (%ebp)
#elif KIND == 4
    fadds 128(%ebp,%edi,1)
#elif KIND == 5
    fiaddl 128(%ebp,%edi,1)
#elif KIND == 6
    fcoms 128(%ebp)
#elif KIND == 7
    fnstsw 0x8f200
#elif KIND == 8
    .byte 0x66
    fnstcw 0x8f200
#elif KIND == 9
    fcoml 128(%ebp)
#elif KIND == 10
    fimull 128(%ebp)
#elif KIND == 11
    fisubl 128(%ebp)
#elif KIND == 12
    fisubrl 128(%ebp)
#elif KIND == 13
    fidivl 128(%ebp)
#elif KIND == 14
    fidivrl 128(%ebp)
#elif KIND == 15
    fcomps 128(%ebp)
    fld1
#elif KIND == 16
    fcompl 128(%ebp)
    fld1
#else
#error unsupported KIND
#endif
hot_end:
    decl %ecx
    jnz hot_loop
    fistpl 0x8f204
    fwait
    cmpl $1,0x8f204
    jne fail
#if KIND == 0 || KIND == 8
    cmpw $0x037f,0x8f200
    jne fail
#elif KIND == 2
    cmpl $1,(%ebp)
    jne fail
#elif KIND == 3
    cmpl $0x3f800000,(%ebp)
    jne fail
#endif
    jmp pair_u
    .balign 32,0x90
pair_u:
    movl $0x23456789,%ebx
pair_v:
    movl $0x3456789a,%edx
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
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
