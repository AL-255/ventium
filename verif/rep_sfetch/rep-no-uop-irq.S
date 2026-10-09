/* A held external IRQ follows a real REP retirement. The handler verifies
 * the exact committed memory prefix before resuming the remaining elements. */
#ifndef COUNT
#define COUNT 32
#endif
#ifndef OFFSET
#define OFFSET 17
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
    movw $0x17,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl %cr0,%eax
    andl $0x9fffffff,%eax
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
    /* IDT vector 0x40, interrupt gate. */
    movl $irq_handler,%ebx
    movl %ebx,%eax
    andl $0xffff,%eax
    orl $0x00080000,%eax
    movl %eax,0x1200
    movl %ebx,%eax
    andl $0xffff0000,%eax
    orl $0x00008e00,%eax
    movl %eax,0x1204
    movw $0x7ff,0x480
    movl $0x1000,0x482
    lidt 0x480
    movl $0,0x2100
    movl $0x2000,%esi
    movl $0x4000,%edi
    movl $0x12345678,%eax
    movl $COUNT,%ecx
init:
    movl %eax,(%esi)
    movl $0xdeadbeef,(%edi)
    addl $0x01020304,%eax
    addl $4,%esi
    addl $4,%edi
    loop init
    movl $0x2000,%esi
    movl $0x4000,%edi
    movl $COUNT,%ecx
    sti
    nop
    jmp rep_hot
    .balign 32
    .space OFFSET,0x90
    .global rep_hot
rep_hot:
    rep movsl
    cli
    cmpl $1,0x2100
    jne fail
    testl %ecx,%ecx
    jne fail
    cmpl $(0x2000+COUNT*4),%esi
    jne fail
    cmpl $(0x4000+COUNT*4),%edi
    jne fail
    movl $0x4000,%edi
    movl $0x12345678,%eax
    movl $COUNT,%ecx
check_final:
    cmpl (%edi),%eax
    jne fail
    addl $4,%edi
    addl $0x01020304,%eax
    loop check_final
    movl $0x42,%eax
    jmp exit
fail:
    movl $0x43,%eax
exit:
    movw $0xf4,%dx
    outb %al,%dx
    hlt
    .balign 16
    .global irq_handler,irq_checks,irq_return
irq_handler:
    pushal
irq_checks:
    incl 0x2100
    cmpl $1,0x2100
    jne fail
    /* The synchronizer may allow an already-started next element to finish.
     * Its entire memory effect must precede the IRQ; no later element may. */
    cmpl $rep_hot,32(%esp)
    jne fail
    cmpl $8,36(%esp)
    jne fail
    testl $0x200,40(%esp)
    jz fail
    cmpl $1,%ecx
    jb fail
    cmpl $COUNT,%ecx
    jae fail
    movl %ecx,0x2104
    movl %esi,0x2108
    movl %edi,0x210c
    movl $COUNT,%edx
    subl %ecx,%edx
    leal 0x2000(,%edx,4),%eax
    cmpl %eax,%esi
    jne fail
    leal 0x4000(,%edx,4),%eax
    cmpl %eax,%edi
    jne fail
    movl $0x4000,%edi
    movl $0x12345678,%eax
check_prefix:
    cmpl (%edi),%eax
    jne fail
    addl $4,%edi
    addl $0x01020304,%eax
    decl %edx
    jnz check_prefix
check_suffix:
    cmpl $0xdeadbeef,(%edi)
    jne fail
    addl $4,%edi
    loop check_suffix
    popal
irq_return:
    iret
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
