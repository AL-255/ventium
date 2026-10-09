/* Cold paged system, real FDIV -> acquired m64 -> independent integer work.
 * DRAIN=1 inserts architectural FWAIT, a serialization negative control.
 * DATA_OFFSET=29 crosses a cache line; RELOC=1 uses nonzero CS/DS bases. */
#ifndef KIND
#define KIND 0
#endif
#ifndef DRAIN
#define DRAIN 0
#endif
#ifndef RELOC
#define RELOC 0
#endif
#ifndef DATA_OFFSET
#define DATA_OFFSET 0
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
    movl $(0x8f100+DATA_OFFSET),%ebp
#if KIND == 7
    movl $-7,(%ebp)
    movl $-1,4(%ebp)
#else
    movl $0,(%ebp)
    movl $0x40100000,4(%ebp)
#endif
    movl $0x40400000,64(%ebp)
    movl $0x40c00000,68(%ebp)
    fninit
    xorl %eax,%eax
    xorl %ebx,%ebx
    xorl %esi,%esi
    xorl %edi,%edi
    movl $16,%ecx
    jmp hot_loop
    .balign 32,0x90
    .global hot_loop,source_op,integer_begin,integer_end,pair_u,pair_v
hot_loop:
    flds 64(%ebp)
    flds 68(%ebp)
    fdiv %st(1),%st
#if DRAIN
    fwait
#endif
source_op:
#if KIND == 0
    faddl (%ebp)
#elif KIND == 1
    fmull (%ebp)
#elif KIND == 2
    fsubl (%ebp)
#elif KIND == 3
    fsubrl (%ebp)
#elif KIND == 4
    fdivl (%ebp)
#elif KIND == 5
    fdivrl (%ebp)
#elif KIND == 6
    fldl (%ebp)
#elif KIND == 7
    fildq (%ebp)
#else
#error unsupported KIND
#endif
integer_begin:
    .rept 4
    incl %eax
    incl %ebx
    incl %esi
    incl %edi
    .endr
integer_end:
    fwait
    fnstenv 0x8f200
    cmpl $source_op,0x8f20c
    jne fail
    cmpw $0x18,0x8f210
    jne fail
    cmpl $(0x8f100+DATA_OFFSET),0x8f214
    jne fail
    cmpw $0x20,0x8f218
    jne fail
    fldenv 0x8f200
    fstpl 0x8f280
    cmpl $0,0x8f280
    jne fail
#if KIND == 0
    cmpl $0x40180000,0x8f284
#elif KIND == 1
    cmpl $0x40200000,0x8f284
#elif KIND == 2
    cmpl $0xc0000000,0x8f284
#elif KIND == 3 || KIND == 5
    cmpl $0x40000000,0x8f284
#elif KIND == 4
    cmpl $0x3fe00000,0x8f284
#elif KIND == 6
    cmpl $0x40100000,0x8f284
#elif KIND == 7
    cmpl $0xc01c0000,0x8f284
#endif
    jne fail
#if KIND >= 6
    fstp %st(0)
#endif
    fstp %st(0)
    decl %ecx
    jnz hot_loop
    cmpl $64,%eax
    jne fail
    cmpl $64,%ebx
    jne fail
    cmpl $64,%esi
    jne fail
    cmpl $64,%edi
    jne fail
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
