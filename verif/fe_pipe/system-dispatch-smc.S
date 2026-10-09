/* Cold CPU-store instruction-cache invalidation of a directly dispatched ADDW.
 * OFFSET 31 makes the instruction cross an I-cache line. The replacement is
 * normal guest self-modifying code, followed by a taken control transfer.
 */
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
    xorl %eax,%eax
    xorl %edi,%edi
    movl $8,%ecx
    movl $TARGET,%ebp
first:
    call *%ebp
    decl %ecx
    jnz first
    cmpl $56,%eax
    jne fail
    movb $9,TARGET+3
    movl $8,%ecx
    jmp second
second:
    call *%ebp
    decl %ecx
    jnz second
    cmpl $128,%eax
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
    .set pair_u,TARGET+4
    .set pair_v,TARGET+9
template:
    .byte 0x66,0x83,0xc0,7
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
