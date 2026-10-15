/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
/* Ordinary real-mode INT/IRET with default and relocated IVTs, then a
 * protected-mode independent integer loop to witness normal U/V execution.
 * No guest state injection, frame editing, or instruction skipping. */
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
    xorl %esi,%esi
    movw $(rm_handler-_start16),0xc0
    movw $0xf000,0xc2
    int $0x30
    cmpw $0x7000,%sp
    jne fail16
    cmpl $1,%esi
    jne fail16
    movw $(rm_handler-_start16),0x10c0
    movw $0xf000,0x10c2
    movw $0x3ff,0x400
    movl $0x1000,0x402
    lidtw 0x400
    int $0x30
    cmpw $0x7000,%sp
    jne fail16
    cmpl $2,%esi
    jne fail16
    movl $0,0x500
    movl $0,0x504
    movl $0x0000ffff,0x508
    movl $0x00cf9a00,0x50c
    movl $0x0000ffff,0x510
    movl $0x00cf9200,0x514
    movw $23,0x410
    movl $0x500,0x412
    lgdtw 0x410
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
    ljmpl $8,$pm32
rm_handler:
    pushw %ax
    incl %esi
    popw %ax
    iretw
fail16:
    movb $0x7f,%al
    outb %al,$0xf4
    hlt
    .code32
    .section .text32,"ax"
pm32:
    movw $16,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x7000,%esp
    xorl %eax,%eax
    xorl %ebx,%ebx
    movl $64,%ecx
1:  addl $1,%eax
    addl $2,%ebx
    decl %ecx
    jnz 1b
    cmpl $64,%eax
    jne fail32
    cmpl $128,%ebx
    jne fail32
    movl $0x524d4952,%edi
    movl $0x42,%eax
    outb %al,$0xf4
    hlt
fail32:
    movl $0x7f,%eax
    outb %al,$0xf4
    hlt
    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    ljmp $0xf000,$_start16_off
