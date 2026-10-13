/* Protected-mode full 108-byte FP-state preservation and pending-#MF probe.
 * CONTROL 0: obsolete opcode; 1: integer NOP roundtrip control; 2: FNOP.
 * A pending unmasked exception must not turn obsolete no-ops into FNOP.
 */
    .section .text16,"ax"
    .code16
    .global _start16, fail16
_start16:
    cli
    cld
    xorw %ax,%ax
    movw %ax,%ds
    movw %ax,%ss
    movl $0x9000,%esp
    movw $fail16_off,6*4
    movw $0xf000,6*4+2
    movl $0,0x500
    movl $0,0x504
    movl $0x0000ffff,0x508
    movl $0x00cf9a00,0x50c
    movl $0x0000ffff,0x510
    movl $0x00cf9200,0x514
    movw $0x17,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl $0x60000031,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long pm_entry
    .word 8
fail16:
    movb $0x43,%al
    outb %al,$0xf4
    hlt
    jmp fail16

    .section .text32,"ax"
    .code32
    .macro gate vector, target
    movl $\target,%eax
    andl $0xffff,%eax
    orl $0x00080000,%eax
    movl %eax,0x600+8*\vector
    movl $\target,%eax
    andl $0xffff0000,%eax
    orl $0x8e00,%eax
    movl %eax,0x604+8*\vector
    .endm
pm_entry:
    movw $0x10,%ax
    movw %ax,%ss
    movw %ax,%ds
    movw %ax,%es
    gate 6, ud_handler
    gate 7, fail
    gate 16, mf_handler
    movw $0x87,0x490
    movl $0x600,0x492
    lidt 0x490
    movl $0,0x1000
    fninit
    fld1
    fldl2t
    fldl2e
    fldpi
    fldlg2
    fldln2
    fldz
    fld1
    fchs
    fnsave 0x2000
#if PENDING
    andw $0xfffe,0x2000
    orw $0x8081,0x2004
#endif
    frstor 0x2000
    movl $0x12345678,%eax
    movl $0x11223344,%edx
    movl $0x55667788,%ebx
    pushl $0x8d7
    popfl
    .global probe, resume
probe:
#if LOCKED
    .byte 0xf0
#endif
#if PREFIX
    .byte 0x66
#endif
#if CONTROL == 1
    .byte 0x90
#elif CONTROL == 2
    .byte 0xd9,0xd0
#else
    .byte 0xdb,OPCODE
#endif
resume:
    pushfl
    popl %ecx
    andl $0xfd7,%ecx
    cmpl $0x8d7,%ecx
    jne fail
    cmpl $0x12345678,%eax
    jne fail
    cmpl $0x11223344,%edx
    jne fail
    cmpl $0x55667788,%ebx
    jne fail
    fnsave 0x2200
#if (CONTROL == 2 && PENDING) || LOCKED
    cmpl $1,0x1000
#else
    cmpl $0,0x1000
#endif
    jne fail
    /* Compare raw images from the SAME machine, including all pointers and
     * all eight 80-bit slots. Reserved-byte policy is unchanged by roundtrip.
     */
    movl $0x2000,%esi
    movl $0x2200,%edi
    movl $27,%ecx
    repe cmpsl
    jne fail
    movb $0x42,%al
    jmp finish
mf_handler:
#if CONTROL != 2 || !PENDING || LOCKED
    jmp fail
#endif
    pushl %ebp
    movl %esp,%ebp
    cmpl $probe,4(%ebp)
    jne fail
    fnclex
    /* The control deliberately clears its pending exception. */
    andw $0x7f00,0x2004
    jmp handled
ud_handler:
#if !LOCKED
    jmp fail
#endif
    pushl %ebp
    movl %esp,%ebp
    cmpl $probe,4(%ebp)
    jne fail
handled:
    cmpl $8,8(%ebp)
    jne fail
    incl 0x1000
    movl $resume,4(%ebp)
    popl %ebp
    iret
fail:
    movb $0x43,%al
finish:
    outb %al,$0xf4
    hlt
    jmp finish
    .section .reset,"ax"
    .code16
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
    .fill 11,1,0x90
