/* Cold LMSW register/m16 witness. CONTROL is a MOV-CR fixture control, not
 * LMSW acceptance. Real-mode LMSW enters PM; another LMSW cannot clear PE.
 * OP32 changes the 66 prefix, never the low-four-bit source semantics.
 */
    .set INITIAL, 0x6000001a
    .set EXPECTED, (INITIAL & ~15) | (VALUE & 15)
    .set SECOND, VALUE ^ 14
    .set EXPECTED2, (INITIAL & ~15) | (SECOND & 14) | 1
    .section .text16,"ax"
    .code16
    .global _start16, fail16
_start16:
    cli
    cld
    xorw %ax,%ax
    movw %ax,%ss
    movw %ax,%ds
    movw %ax,%es
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
    movl $INITIAL,%eax
    movl %eax,%cr0
    movw $VALUE,0x4fff
    movl $0xcafe0000+VALUE,%eax
    movl $0x44332211,%edx
    pushl $0x8d7
    popfl
    .global lmsw_probe
lmsw_probe:
#if CONTROL
    movl $EXPECTED,%ecx
    movl %ecx,%cr0
#else
#if OP32
    .byte 0x66
#endif
#if MEMORY
    .byte 0x0f,0x01,0x36,0xff,0x4f
#else
    .byte 0x0f,0x01,0xf0
#endif
#endif
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
pm_entry:
    movw $0x10,%cx
    movw %cx,%ss
    movw %cx,%ds
    movw %cx,%es
    pushfl
    popl %ecx
    andl $0xfd7,%ecx
    cmpl $0x8d7,%ecx
    jne fail
    cmpl $0xcafe0000+VALUE,%eax
    jne fail
    cmpl $0x44332211,%edx
    jne fail
    movl %cr0,%ecx
    cmpl $EXPECTED,%ecx
    jne fail
    /* Install a deliberate #UD failure gate for the PM sticky-PE probe. */
    movl $fail,%ecx
    andl $0xffff,%ecx
    orl $0x00080000,%ecx
    movl %ecx,0x600+6*8
    movl $fail,%ecx
    andl $0xffff0000,%ecx
    orl $0x8e00,%ecx
    movl %ecx,0x600+6*8+4
    movw $0x7f,0x490
    movl $0x600,0x492
    lidt 0x490
    movw $(SECOND & ~1),0x4fff
    movl $0xbabe0000+(SECOND & ~1),%eax
#if CONTROL
    movl $EXPECTED2,%ecx
    movl %ecx,%cr0
#else
#if !OP32
    .byte 0x66
#endif
#if MEMORY
    .byte 0x0f,0x01,0x35
    .long 0x4fff
#else
    .byte 0x0f,0x01,0xf0
#endif
#endif
    movl %cr0,%ecx
    cmpl $EXPECTED2,%ecx
    jne fail
    cmpl $0xbabe0000+(SECOND & ~1),%eax
    jne fail
    cmpw $(SECOND & ~1),0x4fff
    jne fail
    movb $0x42,%al
    jmp finish
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
