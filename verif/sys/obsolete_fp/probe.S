/* Cold, real-mode obsolete x87 opcode/#NM witness. CONTROL uses FNOP.
 * No pending exception here: FNOP is a fixture control, NOT the proposed fix.
 */
    .section .text16,"ax"
    .code16
    .global _start16, fail16, nm16, probe
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
    movw $nm16_off,7*4
    movw $0xf000,7*4+2
    movw $fail16_off,16*4
    movw $0xf000,16*4+2
    movl $0,0x500
    movl $0x60000010,%eax
    movl %eax,%cr0
    fninit
    fld1
    movl $(0x60000010 | BITS),%eax
    movl %eax,%cr0
    movl $0x12345678,%eax
    movl $0x87654321,%edx
    movl $0x11223344,%ebx
    pushl $0x8d7
    popfl
probe:
#if PREFIX
    .byte 0x66
#endif
#if CONTROL
    .byte 0xd9,0xd0
#else
    .byte 0xdb,OPCODE
#endif
    pushfl
    popl %ecx
    andl $0xfd7,%ecx
    cmpl $0x8d7,%ecx
    jne fail16
    cmpl $0x12345678,%eax
    jne fail16
    cmpl $0x87654321,%edx
    jne fail16
    cmpl $0x11223344,%ebx
    jne fail16
    movl %cr0,%ecx
    cmpl $0x60000010,%ecx
    jne fail16
#if BITS
    cmpl $1,0x500
#else
    cmpl $0,0x500
#endif
    jne fail16
    fnstsw %ax
    cmpw $0x3800,%ax
    jne fail16
    movb $0x42,%al
    outb %al,$0xf4
    hlt
    jmp fail16
nm16:
#if !BITS
    jmp fail16
#endif
    pushl %eax
    pushw %bp
    movw %sp,%bp
    cmpw $probe_off,6(%bp)
    jne fail16
    cmpw $0xf000,8(%bp)
    jne fail16
    movl %cr0,%eax
    cmpl $(0x60000010 | BITS),%eax
    jne fail16
    andl $~12,%eax
    movl %eax,%cr0
    incl 0x500
    addw $(2 + PREFIX),6(%bp)
    popw %bp
    popl %eax
    iret
fail16:
    movb $0x43,%al
    outb %al,$0xf4
    hlt
    jmp fail16
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
    .fill 11,1,0x90
