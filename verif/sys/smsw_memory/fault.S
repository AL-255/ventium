/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * CASE 0: illegal LOCK; 1: null DS; 2: read-only DS; 3: DS limit crossing;
 * 4/5: first page absent/read-only; 6/7: second page absent/read-only;
 * 8: two writable noncontiguous physical pages (successful control).
 * All stores span offset 0xfff. Cache ON, CR0.WP=1, CPL0. Fault handler
 * checks original GPRs, fault PC/error/CR2 and BOTH physical pages before
 * any repair/retry. No partial-store allowance or trace masking.
 */
#if CASE < 0 || CASE > 8
#error Invalid fault case
#endif
    .set CR0_VALUE, 0x0001001b
    .section .text16, "ax"
    .code16
    .global _start16
_start16:
    cli
    cld
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl $0x9000, %esp
    movl $0, 0x500
    movl $0, 0x504
    movl $0x0000ffff, 0x508
    movl $0x00cf9a00, 0x50c
    movl $0x0000ffff, 0x510
    movl $0x00cf9200, 0x514
#if CASE == 3
    movl $0x00000fff, 0x518
#else
    movl $0x0000ffff, 0x518
#endif
#if CASE == 2
    movl $0x00409040, 0x51c
#else
    movl $0x00409240, 0x51c
#endif
    movw $0x1f, 0x480
    movl $0x500, 0x482
    lgdt 0x480
    movl $CR0_VALUE, %eax
    movl %eax, %cr0
    .byte 0x66, 0xea
    .long pm_entry
    .word 8
    .section .text32, "ax"
    .code32
pm_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    .macro gate vector, target
    movl $\target, %eax
    andl $0xffff, %eax
    orl $0x00080000, %eax
    movl %eax, 0x1000+8*\vector
    movl $\target, %eax
    andl $0xffff0000, %eax
    orl $0x8e00, %eax
    movl %eax, 0x1000+8*\vector+4
    .endm
    gate 6, ud_handler
    gate 13, gp_handler
    gate 14, pf_handler
    movw $0x77, 0x490
    movl $0x1000, 0x492
    lidt 0x490
#if CASE >= 4
    /* Distinct frames and writable aliases remain accessible to the handler. */
    movl $0xa5a5a5a5, 0x180ffd
    movl $0xa5a5a5a5, 0x1a0000
    movl $0x12003, 0x11000
    movl $0x13003, 0x11004
    .irp page,0,1,8,0x11,0x12,0x13,0xf0,0xf1
    movl $(\page*4096+3), 0x12000+\page*4
    .endr
#if CASE == 4
    movl $0x180002, 0x13000
#elif CASE == 5
    movl $0x180001, 0x13000
#else
    movl $0x180003, 0x13000
#endif
#if CASE == 6
    movl $0x1a0002, 0x13004
#elif CASE == 7
    movl $0x1a0001, 0x13004
#else
    movl $0x1a0003, 0x13004
#endif
    movl $0x180003, 0x13400
    movl $0x1a0003, 0x13404
    movl $0x11000, %eax
    movl %eax, %cr3
    movl $(CR0_VALUE | 0x80000000), %eax
    movl %eax, %cr0
    .set ALIAS, 0x500000
#else
    movl $0xa5a5a5a5, 0x400ffd
    movl $0xa5a5a5a5, 0x401000
    .set ALIAS, 0x400000
#endif
    movl $0xaabbccdd, %eax
    movl %eax, %cr2
#if CASE == 1
    xorw %ax, %ax
#else
    movw $0x18, %ax
#endif
    movw %ax, %ds
    movl $0x1234001b, %eax
    movl $0x11223344, %ebx
    movl $0x22334455, %ecx
    movl $0x33445566, %edx
    movl $0x44556677, %ebp
    movl $0x55667788, %esi
    movl $0x66778899, %edi
    pushl $0x8d7
    popfl
    .global smsw_probe, smsw_after
smsw_probe:
#if CASE == 0
    .byte 0xf0
#endif
#if CONTROL || !OP32
    .byte 0x66
#endif
#if !ADDR32
    .byte 0x67
#endif
#if CONTROL
    .byte 0x89
#if ADDR32
    .byte 0x05
#else
    .byte 0x06
#endif
#else
    .byte 0x0f, 0x01
#if ADDR32
    .byte 0x25
#else
    .byte 0x26
#endif
#endif
#if ADDR32
    .long 0xfff
#else
    .word 0xfff
#endif
smsw_after:
#if CASE == 8
    pushfl
    pushal
    cmpl $0x001ba5a5, %es:ALIAS+0xffd
    jne fail
    cmpl $0xa5a5a500, %es:ALIAS+0x1000
    jne fail
    jmp success
#else
    jmp fail
#endif
ud_handler:
#if CASE == 0
    pushl $0
    jmp fault_handler
#else
    jmp fail
#endif
gp_handler:
#if CASE >= 1 && CASE <= 3
    jmp fault_handler
#else
    jmp fail
#endif
pf_handler:
#if CASE >= 4 && CASE <= 7
    jmp fault_handler
#else
    jmp fail
#endif
fault_handler:
    pushal
    /* Validate the untouched pre-fault register state before any scratch use. */
    cmpl $0x1234001b, %eax
    jne fail
    cmpl $0x11223344, %ebx
    jne fail
    cmpl $0x22334455, %ecx
    jne fail
    cmpl $0x33445566, %edx
    jne fail
    cmpl $0x44556677, %ebp
    jne fail
    cmpl $0x55667788, %esi
    jne fail
    cmpl $0x66778899, %edi
    jne fail
    cmpl $0x8fd0, %esp
    jne fail
#if CASE == 4 || CASE == 6
    cmpl $2, 32(%esp)
#elif CASE == 5 || CASE == 7
    cmpl $3, 32(%esp)
#else
    cmpl $0, 32(%esp)
#endif
    jne fail
    cmpl $smsw_probe, 36(%esp)
    jne fail
    cmpl $8, 40(%esp)
    jne fail
    movl 44(%esp), %eax
    andl $0xfd7, %eax
    cmpl $0x8d7, %eax
    jne fail
    movl %cr2, %eax
#if CASE == 4 || CASE == 5
    cmpl $0x400fff, %eax
#elif CASE == 6 || CASE == 7
    cmpl $0x401000, %eax
#else
    cmpl $0xaabbccdd, %eax
#endif
    jne fail
    cmpl $0xa5a5a5a5, %es:ALIAS+0xffd
    jne fail
    cmpl $0xa5a5a5a5, %es:ALIAS+0x1000
    jne fail
success:
    movb $0x42, %al
    jmp do_exit
fail:
    movb $0x43, %al
do_exit:
    outb %al, $0xf4
    hlt
    jmp do_exit
    .section .reset, "ax"
    .code16
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
    .fill 11, 1, 0x90
