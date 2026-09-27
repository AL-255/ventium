/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Warm RAM-resident independent FP commands immediately followed by INT3.
 * No FWAIT or state substitution: trap entry must drain real FP owners.
 */
.set RAM, 0x8000
.set COUNT, 0x2000
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
    movl $0,0x4000
    movl $0,0x4004
    movl $0x0000ffff,0x4008
    movl $0x00cf9a00,0x400c
    movl $0x0000ffff,0x4010
    movl $0x00cf9200,0x4014
    movw $23,0x480
    movl $0x4000,0x482
    lgdt 0x480
    movl %cr0,%eax
    andl $0x9ffffff3,%eax
    orl $0x23,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long pm_entry
    .word 8
.code32
.section .text32,"ax"
pm_entry:
    movw $16,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x9000,%esp
    movl $handler,%eax
    movl %eax,%edx
    andl $0xffff,%eax
    orl $0x00080000,%eax
    andl $0xffff0000,%edx
    orl $0x00008e00,%edx
    movl %eax,0x1018
    movl %edx,0x101c
    movw $0x7ff,0x490
    movl $0x1000,0x492
    lidt 0x490
    movl $ram_image,%esi
    movl $RAM,%edi
    movl $ram_end-ram_image,%ecx
    rep movsb
    movl $0,COUNT
    fninit
.rept 8
    fld1
.endr
    movl $64,%ecx
    jmp RAM
after_stream:
    cmpl $64,COUNT
    jne fail
    cmpl $0x9000,%esp
    jne fail
    fnstsw %ax
    testw %ax,%ax
    jne fail
    movl $0x42,%eax
    movw $0xf4,%dx
    outb %al,%dx
    hlt
fail:
    movl $0xee,%eax
    movw $0xf4,%dx
    outb %al,%dx
    hlt
handler:
    pushl %eax
.ifdef BRANCH_TRAP
    cmpl $RAM+15,4(%esp)
.else
    cmpl $RAM+13,4(%esp)
.endif
    jne fail
    incl COUNT
    popl %eax
    iret
.balign 32
ram_image:
.ifdef FXCH_QUEUE
    fdiv %st(1),%st
    fxch %st(1)
    .rept 8
    nop
    .endr
.else
.irp idx,1,2,3,4,5,6
    fadd %st,%st(\idx)
.endr
.endif
.ifdef BRANCH_TRAP
    /* A direct branch after six pending masked x87 owners must retire before
     * the subsequent INT3 only when the opt-in FP-branch path is enabled.
     * INT3 still drains all owners before its handler sees architectural state. */
    jmp 1f
1:
.endif
    int3
    decl %ecx
.ifdef BRANCH_TRAP
    .byte 0x75,0xee  /* 18-byte loop with the extra two-byte branch */
    .byte 0xe9
    .long after_stream-(RAM+23)
.else
    .byte 0x75,0xf0  /* 16-byte loop; RAM-relative displacement */
    .byte 0xe9
    .long after_stream-(RAM+21)
.endif
ram_end:
.code16
.section .reset,"ax"
.global _reset
_reset:
    ljmp $0xf000,$_start16_off
