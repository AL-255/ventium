/* Cold paged CPL3, optionally relocated, direct-dispatch RMW fault/retry.
 * ADDW's read succeeds but its write faults on a user read-only mapping.
 * #PF must save unmodified flags/EIP, then retry exactly once after INVLPG.
 */
#ifndef RELOC
#define RELOC 0
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
    movl $(0x00cffa00 | (RELOC << 28)),0x51c
    movl $0x0000ffff,0x520
    movl $(0x00cff200 | (RELOC << 28)),0x524
    movl $0x20000067,0x528
    movl $0x00008900,0x52c
    movw $0x2f,0x480
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
    movl $0x8eff0,%esp
    movl $0x8eff0,0x2004
    movw $0x10,0x2008
    movw $0x68,0x2066
    movw $0x28,%ax
    ltr %ax
    movl $pf_handler,%eax
    movw %ax,0x1070
    movw $8,0x1072
    movw $0x8e00,0x1074
    shrl $16,%eax
    movw %ax,0x1076
    movw $0x7ff,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $0,0x3000
    movl $0x12027,0x11000
    movl $0x12027,0x11100
    .set p,0
    .rept 20
    movl $(0x63+p*4096),(0x12000+p*4)
    .set p,p+1
    .endr
    .set p,0
    .rept 16
    movl $(0xf0067+p*4096),(0x123c0+p*4)
    .set p,p+1
    .endr
    movl $0x18d067,0x12234
    movl $0x18e063,0x12238
    movl $0x181025,0x12240
    movw $0x7fff,0x181001
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    andl $0x9fffffff,%eax
    orl $0x80000000,%eax
    movl %eax,%cr0
    movw $0x23,%ax
    movw %ax,%ds
    movw %ax,%es
    pushl $0x23
    pushl $0x8dff0
    pushl $0x3002
    pushl $0x1b
    pushl $client
    iretl
client:
    movl $0x90000,%ebp
    movl $8,%ecx
    xorl %esi,%esi
    jmp hot_read
    .balign 32
    .global hot_read,pair_u,pair_v
hot_read:
    movswl 1(%ebp),%eax
pair_u:
    movl $0x12345678,%ebx
pair_v:
    incl %esi
    decl %ecx
    jnz hot_read
    pushl $0x3002
    popfl
    jmp fault_op
    .balign 32
    .global fault_op,after_fault
fault_op:
    addw $1,1(%ebp)
after_fault:
    movzwl 1(%ebp),%eax
    cmpl $0x8000,%eax
    jne fail
    cmpl $8,%esi
    jne fail
    movb $0x42,%al
    jmp exit
pf_handler:
    pushl %eax
    pushl %ds
    movw $0x10,%ax
    movw %ax,%ds
    cmpl $7,8(%esp)
    jne fail
    cmpl $fault_op,12(%esp)
    jne fail
    testl $0x8d5,20(%esp)
    jnz fail
    movl %cr2,%eax
    cmpl $((RELOC << 28) + 0x90001),%eax
    jne fail
    incb 0x3000
    cmpb $1,0x3000
    jne fail
    cmpw $0x7fff,0x90001
    jne fail
    movl $0x181067,0x12240
    movl $((RELOC << 28) + 0x90001),%eax
    invlpg (%eax)
    popl %ds
    popl %eax
    addl $4,%esp
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
