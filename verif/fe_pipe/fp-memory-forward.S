/* Cold, paged x87 registered-result forwarding tests. No imported guest state.
 * KIND 0 FADD32, 1 FLD32+FADDP, 2 FADD64, 3 split32, 4 split64,
 *      5 FILD64+FADDP, 6 FIADD16, 7 FIADD32, 8 FSUB32,
 *      9 FSUBR32, 10 FMUL32. Cold inputs, no restore or guest patch.
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
#ifndef EVENT
#define EVENT 0
#endif
#ifndef EVENT_WARM
#define EVENT_WARM 0
#endif
#ifndef EVENT_PERIOD
#define EVENT_PERIOD 1
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
#elif KIND == 5 || KIND == 6 || KIND == 7
    movl $1,p(%ebp)
    movl $0,(p+4)(%ebp)
#else
    movl $0x3f800000,p(%ebp)
#endif
    .set p,p+32
    .endr
#if EVENT
    /* A real protected-mode INT3 after each four-operation burst; same
     * relocation as the client. Entry must drain all older FP owners. */
    movl $0,0x8f240
    movl $handler,%eax
    movw %ax,0x818
    movw $0x18,0x81a
    movw $0x8e00,0x81c
    shrl $16,%eax
    movw %ax,0x81e
    movw $0x1f,0x480
    movl $(0x800 + RELOC*0x10000000),0x482
    lidt 0x480
#endif
    fninit
#if KIND == 10
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
    faddp %st,%st(1)
#elif KIND == 5
    fildll \disp(%ebp)
    faddp %st,%st(1)
#elif KIND == 6
    fiadds \disp(%ebp)
#elif KIND == 7
    fiaddl \disp(%ebp)
#elif KIND == 8
    fsubs \disp(%ebp)
#elif KIND == 9
    fsubrs \disp(%ebp)
#elif KIND == 10
    fmuls \disp(%ebp)
#else
#error unsupported KIND
#endif
    .endm
    jmp hot_loop
    .balign 32,0x90
    .space OFFSET,0x90
    .global hot_loop,operand0,operand1,operand2,operand3,pair_u,pair_v
hot_loop:
#if EVENT_WARM
    /* Optional diagnostic re-entry sequence. It does not guarantee that
     * priming is eligible after IRET; the runner requires a real witness. */
    movl 0(%ebp),%ebx
    movl $0x3456789a,%edx
#endif
operand0:
    OPERAND 0
operand1:
    OPERAND 32
operand2:
    OPERAND 64
operand3:
    OPERAND 96
#if EVENT
#if EVENT_PERIOD == 2
    /* Leave one ordinary backedge between events so resident admission is
     * exercised, then test the real event boundary after the primed burst. */
    testb $1,%cl
    jnz 1f
#endif
    int3
1:
#endif
    decl %ecx
    jnz hot_loop
    fistpl 0x8f200
    fwait
#if KIND == 8
    cmpl $-64,0x8f200
#elif KIND == 9
    cmpl $0,0x8f200
#elif KIND == 10
    cmpl $1,0x8f200
#else
    cmpl $64,0x8f200
#endif
    jne fail
    cmpl $0x8fff0,%esp
    jne fail
#if EVENT
    cmpl $(16/EVENT_PERIOD),0x8f240
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
#if EVENT
    .global handler
handler:
    incl 0x8f240
    iret
#endif
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
