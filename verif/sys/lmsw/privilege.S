/* Cold CPL1/2/3 and V86 privilege denial. LMSW must #GP(0) before changing
 * CR0. Check the original fault PC, CS, GPR source, CR0 and saved flags.
 * Memory forms use an otherwise accessible operand; no patched guest state.
 */
    .set INITIAL, 0x1001b
    .section .text16,"ax"
    .code16
    .global _start16
_start16:
    cli
    cld
    xorw %ax,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x9000,%esp
    movl $0,0x500
    movl $0,0x504
    movl $0x0000ffff,0x508
    movl $0x00cf9a00,0x50c
    movl $0x0000ffff,0x510
    movl $0x00cf9200,0x514
    movl $0x0000ffff,0x518
    movl $(0x00cf9a00 | (CPL << 13)),0x51c
    movl $0x0000ffff,0x520
    movl $(0x00cf9200 | (CPL << 13)),0x524
    movl $0x30000067,0x528
    movl $0x00008900,0x52c
    movw $0x2f,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl $INITIAL,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long pm_entry
    .word 8
    .section .text32,"ax"
    .code32
pm_entry:
    movw $16,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    .set tss_offset,0
    .rept 26
    movl $0,0x3000+tss_offset
    .set tss_offset,tss_offset+4
    .endr
    movl $0x16000,0x3004
    movl $16,0x3008
    movw $0x68,0x3066
    movw $0x28,%ax
    ltr %ax
    .macro gate vector, target
    movl $\target,%eax
    andl $0xffff,%eax
    orl $0x80000,%eax
    movl %eax,0x1000+8*\vector
    movl $\target,%eax
    andl $0xffff0000,%eax
    orl $0x8e00,%eax
    movl %eax,0x1004+8*\vector
    .endm
    gate 6, fail
    gate 12, fail
    gate 13, gp_handler
    gate 14, fail
    movw $0x77,0x490
    movl $0x1000,0x492
    lidt 0x490
    movw $0xa604,0x4fff
#if V86
    pushl $0
    pushl $0
    pushl $0
    pushl $0
    pushl $0
    pushl $0x9000
    pushl $0x238d7
    pushl $0xf000
    pushl $user_entry_off
#else
    movw $(0x20 | CPL),%ax
    movw %ax,%ds
    movw %ax,%es
    pushl $(0x20 | CPL)
    pushl $0x9000
    pushl $0x8d7
    pushl $(0x18 | CPL)
    pushl $user_entry
#endif
    iret
gp_handler:
    pushal
    cmpl $0xbeefa604,%eax
    jne fail
    cmpl $0x11223344,%ebx
    jne fail
    cmpl $0,32(%esp)
    jne fail
#if V86
    cmpl $lmsw_probe_off,36(%esp)
    jne fail
    cmpl $0xf000,40(%esp)
#else
    cmpl $lmsw_probe,36(%esp)
    jne fail
    cmpl $(0x18 | CPL),40(%esp)
#endif
    jne fail
    movl 44(%esp),%eax
    andl $0x23fd7,%eax
#if V86
    cmpl $0x238d7,%eax
#else
    cmpl $0x8d7,%eax
#endif
    jne fail
    movl %cr0,%eax
    cmpl $INITIAL,%eax
    jne fail
    movb $0x42,%al
    jmp finish
fail:
    movb $0x43,%al
finish:
    outb %al,$0xf4
    hlt
    jmp finish
    .section .textuser,"ax"
#if V86
    .code16
#else
    .code32
#endif
    .global user_entry, lmsw_probe
user_entry:
    movl $0xbeefa604,%eax
    movl $0x11223344,%ebx
lmsw_probe:
#if OP32 != (1-V86)
    .byte 0x66
#endif
#if ADDR32 != (1-V86)
    .byte 0x67
#endif
#if !MEMORY
    .byte 0x0f,0x01,0xf0
#elif ADDR32
    .byte 0x0f,0x01,0x35
    .long 0x4fff
#else
    .byte 0x0f,0x01,0x36
    .word 0x4fff
#endif
    /* If LMSW wrongly executes, force a nonmatching #GP to fail the checker. */
    .byte 0xfa
    .byte 0xf4
    jmp user_entry
    .section .reset,"ax"
    .code16
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
    .fill 11,1,0x90
