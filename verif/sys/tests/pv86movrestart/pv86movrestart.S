/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Generic V86 byte-read restart and restored-segment/context witness.
 * CASE=1: #PF only; 2/3/4: additionally use a SOFTWARE interrupt gate after
 * MOV AL, after INC BX, or after LOOP. These are NOT hardware-IRQ witnesses.
 * Assembly/link checked only: no QEMU/RTL execution result is claimed.
 */
#ifndef CASE
#define CASE 1
#endif
#if CASE < 1 || CASE > 4
#error CASE must be 1..4
#endif

    .set M_PF, 0x2000
    .set M_EVENT, 0x2004
    .set M_CR2, 0x2008
    .set M_FAULT_AX, 0x200c
    .set M_FAULT_BX, 0x2010
    .set M_FAULT_CX, 0x2014
    .set M_FAULT_IP, 0x2018

    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7000, %sp
    movl $0, 0x500
    movl $0, 0x504
    movl $0x0000ffff, 0x508
    movl $0x00cf9a00, 0x50c       /* selector08: flat code, D=1 */
    movl $0x0000ffff, 0x510
    movl $0x00cf9200, 0x514       /* selector10: flat data, B=1 */
    movl $0, 0x518
    movl $0, 0x51c
    movl $0, 0x520
    movl $0, 0x524
    movl $0x30000067, 0x528
    movl $0x00008900, 0x52c       /* selector28: TSS32 base3000 */
    movw $0x2f, 0x480
    movl $0x500, 0x482
    lgdt 0x480
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    .byte 0x66, 0xea
    .long pm32_entry
    .word 0x08

    .code32
    .section .text32, "ax"
pm32_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl $0x90000, %esp
    movl $0x3000, %edi
    xorl %eax, %eax
    movl $26, %ecx
1:  movl %eax, (%edi)
    addl $4, %edi
    loop 1b
    movl $0x88000, 0x3004
    movw $0x10, 0x3008
    movw $0x68, 0x3066
    movw $0x28, %ax
    ltr %ax

    /* Ordinary #GP/#PF gates and a DPL3 SOFTWARE INT30 gate. */
    movl $gp_handler, %ebx
    movl %ebx, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, 0x1068
    movl %ebx, %eax
    andl $0xffff0000, %eax
    orl $0x8e00, %eax
    movl %eax, 0x106c
    movl $pf_handler, %ebx
    movl %ebx, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, 0x1070
    movl %ebx, %eax
    andl $0xffff0000, %eax
    orl $0x8e00, %eax
    movl %eax, 0x1074
    movl $event_handler, %ebx
    movl %ebx, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, 0x1180
    movl %ebx, %eax
    andl $0xffff0000, %eax
    orl $0xee00, %eax             /* present, DPL3, interrupt gate32 */
    movl %eax, 0x1184
    movl $0, 0x1100              /* INT20 intentionally fails DPL */
    movl $0, 0x1104
    movw $0x7ff, 0x490
    movl $0x1000, 0x492
    lidt 0x490

    movl $_v86_lma, %esi
    movl $0x10000, %edi
    movl $_v86_blob_len, %ecx
    addl $3, %ecx
    shrl $2, %ecx
1:  movl (%esi), %eax
    movl %eax, (%edi)
    addl $4, %esi
    addl $4, %edi
    loop 1b

    /* All used low pages are mapped explicitly. ES pages20/21 use known,
     * NONidentity physical backing50/51; page21 alone starts absent. */
    movl $0x12000, %edi
    movl $7, %eax
    movl $145, %ecx             /* pages00..90, including both stacks */
1:  movl %eax, (%edi)
    addl $0x1000, %eax
    addl $4, %edi
    loop 1b
    movl $0x123c0, %edi
    movl $0xf0007, %eax
    movl $16, %ecx              /* resident BIOS/monitor pagesF0..FF */
1:  movl %eax, (%edi)
    addl $0x1000, %eax
    addl $4, %edi
    loop 1b
    movl $0x50007, 0x12080
    movl $0x51006, 0x12084       /* U=1/RW=1/P=0; only PF handler repairs */
    movl $0x12007, 0x11000

    movl $0, M_PF
    movl $0, M_EVENT
    movl $0, M_CR2
    movl $0, M_FAULT_AX
    movl $0, M_FAULT_BX
    movl $0, M_FAULT_CX
    movl $0, M_FAULT_IP
    movl $0, 0x30000
    movl $0, 0x30004
    movl $0, 0x30008
    movl $0xa5421eff, 0x50ffd
    movl $0x807f005a, 0x51001
    movb $0xfe, 0x51005
    movl $0x11000, %eax
    movl %eax, %cr3
    movl %cr0, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0

    pushl $0x3200               /* GS */
    pushl $0x3100               /* FS */
    pushl $0x3000               /* DS, output buffer */
    pushl $0x2000               /* ES, source buffer */
    pushl $0x4000               /* SS */
    pushl $0xf000
    pushl $0x23002              /* VM/IOPL3, IF=0: no external IRQs */
    pushl $0x1000
    pushl $0
    iret
monitor_hang:
    hlt
    jmp monitor_hang

/* #PF PUSHAD layout: err32/EIP36/CS40/flags44/ESP48/SS52/ES56/DS60/FS64/GS68.
 * Change both live data segments and use32-bit instructions deliberately.
 * Do not rewrite the guest frame or saved GPRs: IRETD itself must restore ES. */
    .global pf_handler
pf_handler:
    pushal
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    cmpl $0, M_PF
    jne monitor_fail
    cmpl $4, 32(%esp)           /* !P/read/user, not supervisor or write */
    jne monitor_fail
    movl %cr2, %eax
    movl %eax, M_CR2
    cmpl $0x21000, %eax
    jne monitor_fail
    movl 28(%esp), %eax
    movl %eax, M_FAULT_AX
    cmpl $0xabcd8142, %eax      /* three retired reads; AL must NOT change */
    jne monitor_fail
    movl 16(%esp), %eax
    movl %eax, M_FAULT_BX
    cmpl $0x13571000, %eax
    jne monitor_fail
    movl 24(%esp), %eax
    movl %eax, M_FAULT_CX
    cmpl $0x24680006, %eax       /* LOOP is16-bit despite high ECX sentinel */
    jne monitor_fail
    cmpl $0x87650003, 0(%esp)
    jne monitor_fail
    cmpl $0x11223344, 4(%esp)
    jne monitor_fail
    cmpl $0x55aa55aa, 8(%esp)
    jne monitor_fail
    cmpl $0xdead0066, 20(%esp)
    jne monitor_fail
    movl 36(%esp), %eax
    movl %eax, M_FAULT_IP
    cmpl $(read_byte-v86_entry), %eax
    jne monitor_fail
    cmpw $0x1000, 40(%esp)
    jne monitor_fail
    movl 44(%esp), %eax
    andl $0x23000, %eax
    cmpl $0x23000, %eax
    jne monitor_fail
    cmpl $0xf000, 48(%esp)
    jne monitor_fail
    cmpw $0x4000, 52(%esp)
    jne monitor_fail
    cmpw $0x2000, 56(%esp)
    jne monitor_fail
    cmpw $0x3000, 60(%esp)
    jne monitor_fail
    cmpw $0x3100, 64(%esp)
    jne monitor_fail
    cmpw $0x3200, 68(%esp)
    jne monitor_fail
    /* Previous page-end BYTE read must have succeeded without probing page21. */
    cmpl $0x00421eff, 0x30000
    jne monitor_fail
    movl $1, M_PF
    movl $0x51007, 0x12084
    movl %cr3, %eax
    movl %eax, %cr3
    movl $M_PF, %ebx
    movl %es:(%ebx), %ecx       /* last memory context is32-bit ES(flat) */
    popal
    addl $4, %esp
    iret

/* A deterministic software event with a real V86-to-CPL0 gate/frame/IRETD.
 * Unlike asynchronous IRQs its exact source boundary is known. After PUSHAD:
 * EIP32/CS36/flags40/ESP44/SS48/ES52/DS56/FS60/GS64 (no error code).
 * All transient handler registers may differ, but the saved frame is immutable. */
    .global event_handler
event_handler:
    pushal
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movl M_EVENT, %esi          /* ordinal0..8 before increment */
    cmpl $9, %esi
    jae monitor_fail
    cmpw $0x1000, 36(%esp)
    jne monitor_fail
    movl 40(%esp), %eax
    andl $0x23000, %eax
    cmpl $0x23000, %eax
    jne monitor_fail
    cmpl $0xf000, 44(%esp)
    jne monitor_fail
    cmpw $0x4000, 48(%esp)
    jne monitor_fail
    cmpw $0x2000, 52(%esp)
    jne monitor_fail
    cmpw $0x3000, 56(%esp)
    jne monitor_fail
    cmpw $0x3100, 60(%esp)
    jne monitor_fail
    cmpw $0x3200, 64(%esp)
    jne monitor_fail
    cmpl $0x11223344, 4(%esp)
    jne monitor_fail
    cmpl $0x55aa55aa, 8(%esp)
    jne monitor_fail
    cmpl $0xdead0066, 20(%esp)
    jne monitor_fail
#if CASE == 2
    cmpl $(after_read_event-v86_entry), 32(%esp)
    jne monitor_fail
    movl %esi, %edi
#else
#if CASE == 3
    cmpl $(after_inc_event-v86_entry), 32(%esp)
    jne monitor_fail
#elif CASE == 4
    cmpl $8, %esi
    je 1f
    cmpl $(after_taken_event-v86_entry), 32(%esp)
    jne monitor_fail
    jmp 2f
1:  cmpl $(after_final_event-v86_entry), 32(%esp)
    jne monitor_fail
2:
#else
    jmp monitor_fail           /* CASE1 must never take the software gate */
#endif
    leal 1(%esi), %edi
#endif
    leal 0x87650000(%edi), %eax
    cmpl %eax, 0(%esp)
    jne monitor_fail
    leal 0x13570ffd(%edi), %eax
    cmpl %eax, 16(%esp)
    jne monitor_fail
    movl $0x24680009, %eax
#if CASE == 4
    subl %edi, %eax
#else
    subl %esi, %eax
#endif
    cmpl %eax, 24(%esp)
    jne monitor_fail
    movl 28(%esp), %eax
    andl $0xffff0000, %eax
    cmpl $0xabcd0000, %eax
    jne monitor_fail
    movzbl 28(%esp), %eax
    movzbl expected_data(,%esi,1), %edx
    cmpl %edx, %eax
    jne monitor_fail
    movzbl 29(%esp), %eax
    leal 0x7e(%edi), %edx
    cmpl %edx, %eax
    jne monitor_fail
    incl M_EVENT
    /* Explicit addr32+operand32 memory/register context before IRETD. */
    movl $M_EVENT, %ebx
    movl %es:(%ebx), %ecx
    movl $0x01234567, %eax
    movl $0x89abcdef, %edx
    movl $0x76543210, %ebp
    popal
    iret

gp_handler:
    /* Only the deliberate final INT20 may exit; an early #GP is a failure. */
    cmpl $(0x56524d00+CASE), %ebp
    jne monitor_fail
    cmpl $0x102, 0(%esp)
    jne monitor_fail
    cmpl $(success_trap-v86_entry), 4(%esp)
    jne monitor_fail
    cmpw $0x1000, 8(%esp)
    jne monitor_fail
    movl 12(%esp), %eax
    andl $0x23000, %eax
    cmpl $0x23000, %eax
    jne monitor_fail
    movw $0x10, %ax
    movw %ax, %ds
    cmpl $1, M_PF
    jne monitor_fail
#if CASE == 1
    cmpl $0, M_EVENT
#else
    cmpl $9, M_EVENT
#endif
    jne monitor_fail
    cmpl $0xa5421eff, 0x30000
    jne monitor_fail
    cmpl $0x807f005a, 0x30004
    jne monitor_fail
    cmpb $0xfe, 0x30008
    jne monitor_fail
    movl $0x42, %eax
    movw $0xf4, %dx
    outb %al, %dx
    jmp monitor_hang
monitor_fail:
    movl $(0xbad10000+CASE), %ebp
    movl $0x43, %eax
    movw $0xf4, %dx
    outb %al, %dx
    jmp monitor_hang

    .section .rodata, "a"
expected_data:
    .byte 0xff, 0x1e, 0x42, 0xa5, 0x5a, 0x00, 0x7f, 0x80, 0xfe

    .code16
    .section .text_v86, "ax"
    .global v86_entry, read_byte, inc_bx, loop_step, success_trap
v86_entry:
    movl $0xabcd7e99, %eax
    movl $0x13570ffd, %ebx
    movl $0x24680009, %ecx
    movl $0xdead0066, %edx
    movl $0x11223344, %esi
    movl $0x87650000, %edi
    movl $0x55aa55aa, %ebp
read_byte:
    movb %es:(%bx), %al        /* exact26 8A07; no ES reload after any IRETD */
#if CASE == 2
    int $0x30
after_read_event:
#endif
    movb %al, %ds:(%di)
    incb %ah
inc_bx:
    incw %bx
    incw %di
#if CASE == 3
    int $0x30
after_inc_event:
#endif
loop_step:
    loop another_byte          /* CX only, not sentinel-bearing full ECX */
#if CASE == 4
    int $0x30
after_final_event:
#endif
    /* Output compares in the monitor do not overwrite the operands under test. */
    cmpl $0xabcd87fe, %eax
    jne v86_fail
    cmpl $0x13571006, %ebx
    jne v86_fail
    cmpl $0x24680000, %ecx
    jne v86_fail
    cmpl $0x87650009, %edi
    jne v86_fail
    cmpl $0x11223344, %esi
    jne v86_fail
    cmpl $0xdead0066, %edx
    jne v86_fail
    cmpl $0x55aa55aa, %ebp
    jne v86_fail
    movl $(0x56524d00+CASE), %ebp
success_trap:
    int $0x20
v86_hang:
    jmp v86_hang
another_byte:
#if CASE == 4
    int $0x30
after_taken_event:
#endif
    jmp read_byte
v86_fail:
    movl $(0xbad20000+CASE), %ebp
    int $0x20
    jmp v86_hang

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
