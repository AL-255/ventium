/* Cold RAM-resident x87 SMC. Change FNSTCW to FNSTSW by an ordinary CPU
 * store, then take a control transfer. Both phases must observe new bytes. */
#ifndef OFFSET
#define OFFSET 0
#endif
    .set TARGET,0x8000+OFFSET
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
    movw $0x17,0x480
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
    movl $0x90000,%esp
    movl $template,%esi
    movl $TARGET,%edi
    movl $(template_end-template),%ecx
    rep movsb
    fninit
    fld1
    xorl %eax,%eax
    xorl %edi,%edi
    movl $8,%ecx
    movl $TARGET,%ebp
first:
    call *%ebp
    decl %ecx
    jnz first
    cmpw $0x037f,0x2100
    jne fail
    movb $0xdd,TARGET
    movl $8,%ecx
    jmp second
second:
    call *%ebp
    decl %ecx
    jnz second
    cmpw $0x3800,0x2100
    jne fail
    cmpl $16,%edi
    jne fail
    movb $0x42,%al
    jmp exit
fail:
    movb $0x43,%al
exit:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    .global hot_op,pair_u,pair_v
    .set hot_op,TARGET
    .set pair_u,TARGET+6
    .set pair_v,TARGET+11
template:
    fnstcw 0x2100
    movl $0x12345678,%ebx
    incl %edi
    ret
template_end:
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
