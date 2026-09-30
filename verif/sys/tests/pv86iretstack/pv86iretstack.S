/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Generic paged V86 IRET stack-address/extent witnesses. CASE=1..5:
 * 1 IRETD with nonzero ESP high half; 2 IRETD SP wrap; 3 IRETW FLAGS
 * ending at a mapped-page boundary, following page absent; 4 full V86 ESP
 * restore from a CPL0 SS.B=0 handler; 5 ordinary low-ESP IRETD control.
 * No workload-specific behavior.
 */
#ifndef CASE
#define CASE 1
#endif
#if CASE < 1 || CASE > 5
#error CASE must be 1..5
#endif

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
    movl $0x00cf9a00, 0x50c       /* code32 flat, selector08 */
    movl $0x0000ffff, 0x510
    movl $0x00cf9200, 0x514       /* data32 flat, selector10 */
    movl $0x0000ffff, 0x518
    movl $0x00009208, 0x51c       /* stack16 base80000, selector18 */
    movl $0, 0x520
    movl $0, 0x524
    movl $0x30000067, 0x528
    movl $0x00008900, 0x52c       /* TSS32 base3000, selector28 */
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
    movl $gp_handler, %ebx
    movl %ebx, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, 0x1068            /* #GP */
    movl %ebx, %eax
    andl $0xffff0000, %eax
    orl $0x8e00, %eax
    movl %eax, 0x106c
    movl $fault_handler, %ebx
    movl %ebx, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, 0x1070            /* #PF */
    movl %ebx, %eax
    andl $0xffff0000, %eax
    orl $0x8e00, %eax
    movl %eax, 0x1074
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
    movl $0x12000, %edi
    movl $7, %eax
    movl $65, %ecx
1:  movl %eax, (%edi)
    addl $0x1000, %eax
    addl $4, %edi
    loop 1b
    movl $0x12200, %edi
    movl $0x80007, %eax
    movl $17, %ecx
1:  movl %eax, (%edi)
    addl $0x1000, %eax
    addl $4, %edi
    loop 1b
    movl $0x123c0, %edi
    movl $0xf0007, %eax
    movl $16, %ecx
1:  movl %eax, (%edi)
    addl $0x1000, %eax
    addl $4, %edi
    loop 1b
    movl $0x40007, 0x12080       /* SS:0000 page20 -> physical40 */
    movl $0x3e007, 0x120b8       /* SS:E000 page2E -> physical3E */
#if CASE == 3
    movl $0, 0x120bc             /* page2F absent, never architecturally read */
#else
    movl $0x3f007, 0x120bc       /* SS:F000 page2F -> physical3F */
#endif
    movl $0x12007, 0x11000
    movl $0x11000, %eax
    movl %eax, %cr3
    movl %cr0, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0
#if CASE == 4
    movw $0x18, %ax
    movw %ax, %ss
    movl $0x7000, %esp           /* 16-bit monitor stack, upperESP zero */
#endif
    pushl $0                     /* GS */
    pushl $0                     /* FS */
    pushl $0x2000                /* DS */
    pushl $0x2000                /* ES */
    pushl $0x2000                /* SS */
#if CASE == 4
    pushl $0xcafef000            /* FULL guestESP must replace handlerESP */
#else
    pushl $0xf000
#endif
    pushl $0x23002               /* VM, IOPL3, IF clear */
    pushl $0x1000
    pushl $0
    iret
monitor_hang:
    hlt
    jmp monitor_hang

gp_handler:
    /* DPL0 INT20 deliberately exits V86; a premature #GP cannot count as
     * success. Check the immutable saved source CS:EIP, VM/IOPL, and marker. */
    cmpl $(0x49525300+CASE), %ebp
    jne fault_handler
    cmpl $(success_trap-v86_entry), 4(%esp)
    jne fault_handler
    cmpw $0x1000, 8(%esp)
    jne fault_handler
    movl 12(%esp), %eax
    andl $0x23000, %eax
    cmpl $0x23000, %eax
    jne fault_handler
    movl $0x42, %eax
    movw $0xf4, %dx
    outb %al, %dx
    jmp monitor_hang
fault_handler:
    movw $0x10, %ax
    movw %ax, %ds
    movl %cr2, %eax
    movl %eax, 0x2000
    movl $(0x50460000+CASE), %ebp
    movl $(0xe0+CASE), %eax
    movw $0xf4, %dx
    outb %al, %dx
    jmp monitor_hang

    .code16
    .section .text_v86, "ax"
    .global v86_entry, tested_iret, returned, success_marker
v86_entry:
#if CASE == 1 || CASE == 5
#if CASE == 1
    movl $0xdeadf008, %esp
#else
    movl $0x0000f008, %esp
#endif
    movl %esp, %esi
    pushl $2                     /* attempted VM/IOPL clear must be ignored */
    pushl $0x1000
    pushl $(returned-v86_entry)
tested_iret:
    .byte 0x66, 0xcf
#elif CASE == 2
    movl $0x00000008, %esp
    movl %esp, %esi
    pushl $2
    pushl $0x1000
    pushl $(returned-v86_entry)
tested_iret:
    .byte 0x66, 0xcf
#elif CASE == 3
    movl $0xdeadf000, %esp
    movl %esp, %esi
    pushw $2
    pushw $0x1000
    pushw $(returned-v86_entry)
tested_iret:
    iret
#else
tested_iret:
    movl $0xcafef000, %esi
#endif
returned:
    cmpl %esi, %esp
    jne v86_bad
    movw %cs, %ax
    cmpw $0x1000, %ax
    jne v86_bad
#if CASE != 4
    movw $0x3000, %ax
    movw %ax, %es                /* identity physical alias for remap witness */
#if CASE == 1 || CASE == 5
    cmpl $(returned-v86_entry), %es:0xeffc
    jne v86_bad
    cmpl $0x1000, %es:0xf000
    jne v86_bad
    cmpl $2, %es:0xf004
    jne v86_bad
#elif CASE == 2
    cmpl $(returned-v86_entry), %es:0xfffc
    jne v86_bad
    movw $0x4000, %ax
    movw %ax, %es
    cmpl $0x1000, %es:0
    jne v86_bad
    cmpl $2, %es:4
    jne v86_bad
#else
    cmpw $(returned-v86_entry), %es:0xeffa
    jne v86_bad
    cmpw $0x1000, %es:0xeffc
    jne v86_bad
    cmpw $2, %es:0xeffe
    jne v86_bad
#endif
#endif
success_marker:
    movl $(0x49525300+CASE), %ebp
success_trap:
    int $0x20
v86_hang:
    jmp v86_hang
v86_bad:
    movl $(0xbad00000+CASE), %ebp
    movl $(0xe0+CASE), %eax
    movw $0xf4, %dx
    outb %al, %dx
    jmp v86_hang

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
