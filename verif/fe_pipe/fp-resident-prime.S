/* Cold, paged x87 resident-window admission tests. No imported guest state.
 * KIND 0 FADD32, 1 FLD32+FADDP, 2 FADD64, 3 split32, 4 split64,
 *      5 FILD64+FADDP, 6 FILD32+FADDP. All operands = 1.
 * POP_KIND optionally selects add/multiply/subtract/reverse-subtract (0..3)
 * for the load/pop cases; defaults preserve the original fixture byte stream.
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
#ifndef POP_KIND
#define POP_KIND 0
#endif
#ifndef CONTROL_WORD
#define CONTROL_WORD 0x037f
#endif
#if KIND == 3
#define BIAS 31
#elif KIND == 4
#define BIAS 25
#else
#define BIAS 0
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
    movl $(0x8f100+BIAS),%ebp
    .set p,0
    .rept 4
#if KIND == 2 || KIND == 4
    movl $0,p(%ebp)
    movl $0x3ff00000,(p+4)(%ebp)
#elif KIND == 5 || KIND == 6
    movl $1,p(%ebp)
    movl $0,(p+4)(%ebp)
#else
    movl $0x3f800000,p(%ebp)
#endif
    .set p,p+32
    .endr
    fninit
#if CONTROL_WORD != 0x037f
    movw $CONTROL_WORD,0x8f300
    fldcw 0x8f300
#endif
#if POP_KIND == 1
    fld1
#else
    fldz
#endif
    movl $16,%ecx
    .macro OPERAND disp
#if KIND == 0 || KIND == 3
    fadds \disp(%ebp)
#elif KIND == 2 || KIND == 4
    faddl \disp(%ebp)
#elif KIND == 1
    flds \disp(%ebp)
#elif KIND == 5
    fildll \disp(%ebp)
#elif KIND == 6
    fildl \disp(%ebp)
#else
#error unsupported KIND
#endif
#if KIND == 1 || KIND == 5 || KIND == 6
#if POP_KIND == 0
    faddp %st,%st(1)
#elif POP_KIND == 1
    .byte 0xde,0xc9 /* FMULP ST(1),ST(0) */
#elif POP_KIND == 2
    .byte 0xde,0xe9 /* FSUBP ST(1),ST(0) */
#elif POP_KIND == 3
    .byte 0xde,0xe1 /* FSUBRP ST(1),ST(0) */
#else
#error unsupported POP_KIND
#endif
#endif
    .endm
    jmp hot_loop
    .balign 32,0x90
    .space OFFSET,0x90
    .global hot_loop,operand0,operand1,operand2,operand3,pair_u,pair_v
hot_loop:
operand0:
    OPERAND 0
operand1:
    OPERAND 32
operand2:
    OPERAND 64
operand3:
    OPERAND 96
    decl %ecx
    jnz hot_loop
    fistpl 0x8f200
    fwait
#if POP_KIND == 1
    cmpl $1,0x8f200
#elif POP_KIND == 2
    cmpl $-64,0x8f200
#elif POP_KIND == 3
    cmpl $0,0x8f200
#else
    cmpl $64,0x8f200
#endif
    jne fail
    cmpl $0x8fff0,%esp
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
