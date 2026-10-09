/* Cold x87 exact-byte capture at byte 17: normal, TF, RF, TS and EM visits.
 * #NM must precede the store; #DB must follow it. No debugger stepping. */
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
    movl $nm_handler,%eax
    movw %ax,0x1038
    movw $8,0x103a
    movw $0x8e00,0x103c
    shrl $16,%eax
    movw %ax,0x103e
    movw $0x7ff,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $0,0x2000
    movl $0,0x2004
    fninit
    xorl %esi,%esi
    xorl %eax,%eax
prepare:
    movw $0xdead,0x2100
    movl %cr0,%eax
    andl $~12,%eax
    cmpl $4,%esi
    jne 8f
    orl $8,%eax
8:  cmpl $5,%esi
    jne 9f
    orl $4,%eax
9:  movl %eax,%cr0
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
    .balign 32,0x90
    .space 17,0x90
    .global hot_op,hot_after,pair_u,pair_v
hot_op:
    fnstcw 0x2100
hot_after:
    cmpw $0x037f,0x2100
    jne fail
    jmp pair_u
    .balign 32,0x90
pair_u:
    movl $0x12345678,%ebx
pair_v:
    incl %edi
    incl %esi
    cmpl $8,%esi
    jne prepare
    cmpl $2,0x2004
    jne fail
    cmpl $1,0x2000
    jne fail
    movb $0x42,%al
    jmp exit
db_handler:
    cmpw $0x037f,0x2100
    jne fail
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
nm_handler:
    cmpl $hot_op,(%esp)
    jne fail
    cmpw $0xdead,0x2100
    jne fail
    pushl %eax
    movl %cr0,%eax
    andl $~12,%eax
    movl %eax,%cr0
    popl %eax
    incl 0x2004
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
