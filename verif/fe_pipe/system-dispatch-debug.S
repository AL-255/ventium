/* Cold TF/RF ownership test for protected-mode direct reference dispatch.
 * Eight visits to the same ADDW: visit 2 has TF, visit 3 has RF. Debug modes
 * must retain ordinary S_DECODE, and later visits must not inherit old TF/RF.
 */
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
    movl $db_handler,%eax
    movw %ax,0x1008
    movw $8,0x100a
    movw $0x8e00,0x100c
    shrl $16,%eax
    movw %ax,0x100e
    movw $0x7ff,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $0,0x2000
    xorl %esi,%esi
    xorl %eax,%eax
prepare:
    movl $2,%edx
    cmpl $2,%esi
    jne 1f
    orl $0x100,%edx
1:  cmpl $3,%esi
    jne 2f
    orl $0x10000,%edx
2:  pushl %edx
    pushl $8
    pushl $hot_op
    iretl
    .balign 32
    .global hot_op,hot_after,pair_u,pair_v
hot_op:
    addw $7,%ax
hot_after:
pair_u:
    movl $0x12345678,%ebx
pair_v:
    incl %edi
    incl %esi
    cmpl $8,%esi
    jne prepare
    cmpl $56,%eax
    jne fail
    cmpl $1,0x2000
    jne fail
    movb $0x42,%al
    jmp exit
db_handler:
    cmpl $hot_after,(%esp)
    jne fail
    testl $0x100,8(%esp)
    jz fail
    pushl %eax
    movl %dr6,%eax
    testl $0x4000,%eax
    jz fail
    popl %eax
    incl 0x2000
    andl $~0x100,8(%esp)
    iretl
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
