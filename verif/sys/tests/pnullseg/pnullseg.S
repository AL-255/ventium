/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Strict protected-mode null data-segment witness; VEN_SEG_ENFORCE required.
 * Intel 243191-001 MOV pp.3-287/3-289, not QEMU softmmu, is the oracle.
 * Four precise #GP(0)s; six legal controls. No paging or task-switch dependency.
 * All handler/test bookkeeping uses SS, even while DS or ES is null.
 */
    .set TARGET,       0x9000
    .set FAULT_COUNT,  0x20000
    .set ERRORS,       0x20004
    .set EXPECT_PC,    0x20008
    .set RESUME_PC,    0x2000C
    .set EXPECT_DS,    0x20010
    .set EXPECT_ES,    0x20014
    .set CONTROLS,     0x20018
    .set FLAG_SAVE,    0x2001C
    .set FLAGS_MASK,   0x003E7FD5 /* defined EFLAGS except fault-image RF */
    .set FLAGS_VALUE,  0x00000CD5 /* status flags+DF set; IF/TF clear */

    .macro stage fault, resume, ds, es
    movl $\fault,%ss:EXPECT_PC
    movl $\resume,%ss:RESUME_PC
    movl $\ds,%ss:EXPECT_DS
    movl $\es,%ss:EXPECT_ES
    pushl $0x00000CD7
    popfl
    movl $0x12345678,%eax
    movl $0x23456789,%ecx
    movl $0x3456789A,%edx
    movl $0x456789AB,%ebx
    movl $0x56789ABC,%ebp
    movl $0x6789ABCD,%esi
    movl $0x789ABCDE,%edi
    .endm

    .macro restored count
    /* Capture flags BEFORE checker CMPs; POP-to-memory is SS-qualified. */
    pushfl
    popl %ss:FLAG_SAVE
    cmpl $0x12345678,%eax
    jne fail
    cmpl $0x23456789,%ecx
    jne fail
    cmpl $0x3456789A,%edx
    jne fail
    cmpl $0x456789AB,%ebx
    jne fail
    cmpl $0x90000,%esp
    jne fail
    cmpl $0x56789ABC,%ebp
    jne fail
    cmpl $0x6789ABCD,%esi
    jne fail
    cmpl $0x789ABCDE,%edi
    jne fail
    movl %ss:FLAG_SAVE,%eax
    andl $FLAGS_MASK,%eax
    cmpl $FLAGS_VALUE,%eax
    jne fail
    cmpl $\count,%ss:FAULT_COUNT
    jne fail
    cmpl $0,%ss:ERRORS
    jne fail
    cmpl $0xAABBCCDD,%ss:TARGET
    jne fail
    cmpl $0x13579BDF,%ss:TARGET-4
    jne fail
    cmpl $0x2468ACE0,%ss:TARGET+4
    jne fail
    .endm

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
    /* Poison nonpresent GDT[0]: a null load must not consult it. */
    movl $0x0000FFFF,0x0500
    movl $0x00CF120A,0x0504
    movl $0x0000FFFF,0x0508
    movl $0x00CF9A00,0x050C
    movl $0x0000FFFF,0x0510
    movl $0x00CF9200,0x0514
    movw $0x17,0x0480
    movl $0x0500,0x0482
    lgdt 0x0480
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
    .byte 0x66,0xEA
    .long pm_entry
    .word 0x08

    .code32
    .section .text32,"ax"
pm_entry:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw %ax,%fs
    movw %ax,%gs
    movl $0x90000,%esp
    movl $0,FAULT_COUNT
    movl $0,ERRORS
    movl $0,CONTROLS
    movl $0x13579BDF,TARGET-4
    movl $0xAABBCCDD,TARGET
    movl $0x2468ACE0,TARGET+4
    movl $gp_handler,%eax
    movl %eax,%edx
    andl $0xFFFF,%eax
    orl $0x00080000,%eax
    movl %eax,0x1068
    andl $0xFFFF0000,%edx
    orl $0x00008E00,%edx
    movl %edx,0x106C
    movw $0x07FF,0x0490
    movl $0x1000,0x0492
    lidt 0x0490

    /* Loading null DS itself is legal. Only the memory instruction faults. */
    xorw %ax,%ax
    movw %ax,%ds
    stage fault_ds_read,after_ds_read,0,0x10
    .global fault_ds_read
fault_ds_read:
    movl TARGET,%eax
after_ds_read:
    restored 1
    stage fault_ds_write,after_ds_write,0,0x10
    .global fault_ds_write
fault_ds_write:
    movl %eax,TARGET
after_ds_write:
    restored 2

    /* Explicit SS override and default SS (%EBP) remain legal with null DS. */
    movl %ss:TARGET,%eax
    cmpl $0xAABBCCDD,%eax
    jne fail
    incl %ss:CONTROLS
    movl $0x11223344,%ss:TARGET
    cmpl $0x11223344,%ss:TARGET
    jne fail
    incl %ss:CONTROLS
    movl $TARGET,%ebp
    movl (%ebp),%eax
    cmpl $0x11223344,%eax
    jne fail
    incl %ss:CONTROLS
    movl $0x55667788,(%ebp)
    cmpl $0x55667788,%ss:TARGET
    jne fail
    incl %ss:CONTROLS
    movl $0xAABBCCDD,%ss:TARGET

    movw $0x10,%ax
    movw %ax,%ds
    movw $3,%ax                   /* RPL bits do not make selector3 nonnull. */
    movw %ax,%es
    stage fault_es_read,after_es_read,0x10,3
    .global fault_es_read
fault_es_read:
    movl %es:TARGET,%ecx
after_es_read:
    restored 3
    stage fault_es_write,after_es_write,0x10,3
    .global fault_es_write
fault_es_write:
    movl %eax,%es:TARGET
after_es_write:
    restored 4

    /* A null ES cannot poison ordinary DS addressing. */
    movl TARGET,%eax
    cmpl $0xAABBCCDD,%eax
    jne fail
    incl %ss:CONTROLS
    movl $0xBCDEF012,TARGET
    cmpl $0xBCDEF012,TARGET
    jne fail
    incl %ss:CONTROLS
    movl $0xAABBCCDD,TARGET
    movw $0x10,%ax
    movw %ax,%es
    cmpl $6,CONTROLS
    jne fail
    cld
    movl $0x600D51A5,%esi
    jmp finish

fail:
    movl $0x90000,%esp
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    incl ERRORS
    movl $0xBAD051A5,%esi
finish:
    movl FAULT_COUNT,%ecx
    movl ERRORS,%edi
    movl CONTROLS,%ebx
    movl TARGET,%ebp
    movl $42,%eax
    testl %edi,%edi
    jz do_exit
    movl $43,%eax
    .global do_exit
do_exit:
    movw $0xF4,%dx
    .global do_out
do_out:
    outb %al,%dx
    cli
halt:
    hlt
    jmp halt

gp_handler:
    pushal
    /* pushad slots: DI,SI,BP,savedSP,BX,DX,CX,AX; error,EIP,CS,flags. */
    cmpl $0,32(%esp)
    jne handler_bad
    movl %ss:EXPECT_PC,%eax
    cmpl %eax,36(%esp)
    jne handler_bad
    cmpw $8,40(%esp)              /* high padding half is not a CS witness */
    jne handler_bad
    cmpl $0x789ABCDE,0(%esp)
    jne handler_bad
    cmpl $0x6789ABCD,4(%esp)
    jne handler_bad
    cmpl $0x56789ABC,8(%esp)
    jne handler_bad
    cmpl $0x8FFF0,12(%esp)         /* pre-faultESP minus4-dword #GP frame */
    jne handler_bad
    cmpl $0x456789AB,16(%esp)
    jne handler_bad
    cmpl $0x3456789A,20(%esp)
    jne handler_bad
    cmpl $0x23456789,24(%esp)
    jne handler_bad
    cmpl $0x12345678,28(%esp)
    jne handler_bad
    movl 44(%esp),%eax
    andl $FLAGS_MASK,%eax         /* RF is intentionally not a no-effect flag. */
    cmpl $FLAGS_VALUE,%eax
    jne handler_bad
    xorw %ax,%ax
    movw %ds,%ax
    movzwl %ax,%eax
    cmpl %ss:EXPECT_DS,%eax
    jne handler_bad
    xorw %ax,%ax
    movw %es,%ax
    movzwl %ax,%eax
    cmpl %ss:EXPECT_ES,%eax
    jne handler_bad
    cmpl $0x13579BDF,%ss:TARGET-4
    jne handler_bad
    cmpl $0xAABBCCDD,%ss:TARGET
    jne handler_bad
    cmpl $0x2468ACE0,%ss:TARGET+4
    jne handler_bad
    incl %ss:FAULT_COUNT
    jmp handler_return
handler_bad:
    incl %ss:ERRORS
handler_return:
    movl %ss:RESUME_PC,%eax
    movl %eax,36(%esp)
    popal
    addl $4,%esp
    iret

    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    ljmp $0xF000,$_start16_off
    .org 16,0
