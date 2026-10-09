/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
/* Real warm code permissions: CPL transition, INVLPG/CR3, physical remap.
 * No host state injection or patched exception frame. CASE0/1 warm supervisor
 * code at CPL0 then enter it at CPL3. CASE2 warms user code, revokes U/S and
 * INVLPGs. CASE3 remaps warm code and reloads CR3, requiring the NEW bytes.
 */
#ifndef CASE
#define CASE 0
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
    movl $0xffff,0x508
    movl $0x00cf9a00,0x50c
    movl $0xffff,0x510
    movl $0x00cf9200,0x514
    movl $0xffff,0x518
    movl $0x00cffa00,0x51c
    movl $0xffff,0x520
    movl $0x00cff200,0x524
    movl $0x30000067,0x528
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
    movw %ax,%fs
    movw %ax,%gs
    movl $0x90000,%esp
    movl $0x3000,%edi
    movl $26,%ecx
    xorl %eax,%eax
1:  movl %eax,(%edi)
    addl $4,%edi
    loop 1b
    movl $0x88000,0x3004
    movl $0x10,0x3008
    movw $0x68,0x3066
    movw $0x28,%ax
    ltr %ax
    movl $pf_handler,%ebx
    movl $0x1070,%edi
    movl $0x8e00,%edx
    call install_gate
    movl $fail,%ebx
    movl $0x1068,%edi
    call install_gate
    movl $0x1030,%edi
    call install_gate
    movl $finish,%ebx
    movl $0x1200,%edi
    movl $0xee00,%edx
    call install_gate
    movw $0x7ff,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $0x12000,%edi
    movl $3,%eax
    movl $20,%ecx
2:  movl %eax,(%edi)
    addl $0x1000,%eax
    addl $4,%edi
    loop 2b
    movl $0x4007,0x12010
    movl $0x7f007,0x121fc
    movl $0x87003,0x1221c
    movl $0x8f003,0x1223c
    movl $0x123c0,%edi
    movl $0xf0003,%eax
    movl $16,%ecx
3:  movl %eax,(%edi)
    addl $0x1000,%eax
    addl $4,%edi
    loop 3b
    movl $0x12007,0x11000
    movl $0x13007,0x11004
#if CASE < 2
    movl $(target+3),0x13014
#else
    movl $(target+7),0x13014
#endif
    movl $0,0x2000
    movl $0,0x4004
    movl $0x11000,%eax
    movl %eax,%cr3
    movl %cr0,%eax
    andl $0x9fffffff,%eax
    orl $0x80010000,%eax
    movl %eax,%cr0
    movl $8,%ecx
    jmp pair_u
    .balign 32,0x90
    .global pair_u,pair_v
pair_u:
    movl $0x23456789,%esi
pair_v:
    movl $0x3456789a,%ebx
    decl %ecx
    jnz pair_u
    movl $1,%eax
    movl $0x405000,%edi
    call *%edi
    cmpl $1,0x4004
    jne fail
#if CASE == 2
    movl $(target+3),0x13014
    invlpg (0x405000)
#elif CASE == 3
    movl $(replacement+7),0x13014
    movl %cr3,%edx
    movl %edx,%cr3
#endif
    movw $0x23,%ax
    movw %ax,%ds
    movw %ax,%es
    xorl %eax,%eax
    xorl %ebp,%ebp
    pushl $0x23
    pushl $0x80000
    pushl $2
    pushl $0x1b
    pushl $0x405000
    iret
install_gate:
    movl %ebx,%eax
    andl $0xffff,%eax
    orl $0x80000,%eax
    movl %eax,(%edi)
    movl %ebx,%eax
    andl $0xffff0000,%eax
    orl %edx,%eax
    movl %eax,4(%edi)
    ret
    .global pf_handler
pf_handler:
    incl 0x2000
    cmpl $1,0x2000
    jne fail
    cmpl $5,(%esp)
    jne fail
    cmpl $0x405000,4(%esp)
    jne fail
    cmpw $0x1b,8(%esp)
    jne fail
    cmpl $2,12(%esp)
    jne fail
    cmpl $0x80000,16(%esp)
    jne fail
    cmpw $0x23,20(%esp)
    jne fail
    movl %cr2,%edx
    cmpl $0x405000,%edx
    jne fail
    cmpl $1,0x4004
    jne fail
    testl %ebp,%ebp
    jnz fail
    movl $(target+7),0x13014
#if CASE == 1
    movl %cr3,%edx
    movl %edx,%cr3
#else
    invlpg (0x405000)
#endif
    addl $4,%esp
    iret
finish:
    cmpl $2,0x4004
    jne fail
#if CASE == 3
    cmpl $0,0x2000
    jne fail
    cmpl $0x22222222,%ebp
#else
    cmpl $1,0x2000
    jne fail
    cmpl $0x11111111,%ebp
#endif
    jne fail
    movb $0x42,%al
    jmp exit
fail:
    movb $0x43,%al
exit:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    .balign 4096,0x90
target:
    incl 0x4004
    movl $0x11111111,%ebp
    testl %eax,%eax
    jz user_done
    ret
user_done:
    int $0x40
    hlt
    .balign 4096,0x90
replacement:
    incl 0x4004
    movl $0x22222222,%ebp
    int $0x40
    hlt
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
