/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * TF trap after an explicit full-width ESP destination, onto SS.B=0.
 * CASE1 MOV ESP,imm32; CASE2 LEA ESP,[EAX]. The source high half BEEF
 * must change to DEAD before #DB, then implicit frame WB must preserve DEAD.
 */
#ifndef CASE
#define CASE 1
#endif
#if CASE < 1 || CASE > 2
#error CASE must be 1 or2
#endif
    .global case_id, initial_esp, destination_esp, handler_esp
    .global expected_dr6, expected_saved_flags, expected_handler_count
    .set case_id, CASE
    .set initial_esp, 0xBEEF7000
    .set destination_esp, 0xDEAD0000
    .set handler_esp, 0xDEADFFF4
    .set expected_dr6, 0xFFFF4FF0
    .set expected_saved_flags, 0x102
    .set expected_handler_count, 1

    .code16
    .section .text16,"ax"
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
    movl $0x0000FFFF, 0x508
    movl $0x00409B0F, 0x50C
    movl $0x0000FFFF, 0x510
    movl $0x00CF9300, 0x514
    movl $0, 0x518
    movl $0, 0x51C
    movl $0x0000FFFF, 0x520
    movl $0x00009300, 0x524
    movw $0x27, 0x480
    movl $0x500, 0x482
    lgdt 0x480
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    .byte 0x66, 0xEA
    .long _pm32_off
    .word 8

    .code32
    .section .text32,"ax"
    .global pm32_entry, set_tf_popfl, tested_op, tested_end, db_handler
    .global capture_ip, capture_cs, capture_flags, capture_dr6, clear_saved_tf
    .global tested_iret, do_exit, set_exit_port, do_out, fail
pm32_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %fs
    movw %ax, %gs
    movl $0x9000, %esp
    xorl %eax, %eax
    movl %eax, %cr2
    movl %eax, %cr3
    movl $0x400, %eax
    movl %eax, %dr7
    movl $0xFFFF0FF0, %eax
    movl %eax, %dr6
    movl $0, 0x2000
    movl $0, 0x2004
    movl $_db_gate_low, 0x3008
    movl $0x00008F00, 0x300C
    movw $0xF, 0x490
    movl $0x3000, 0x492
    lidt 0x490
    movl $0xA55A5AA5, 0xFFF0
    movl $0x5AA5A55A, 0
    movl $0xBAD0BAD0, 0xFFF4
    movl $0xBAD1BAD1, 0xFFF8
    movl $0xBAD2BAD2, 0xFFFC
    movw $0x20, %ax
    movw %ax, %ss
    movl $0xBEEF7000, %esp
    movl $0xDEAD0000, %eax
    pushl $0x102
set_tf_popfl:
    popfl
    /* POPFL ran with TF=0; only THIS next instruction is stepped. There
     * is no intervening instruction, branch, or stack-pointer staging. */
tested_op:
#if CASE == 1
    movl $0xDEAD0000, %esp
#else
    leal (%eax), %esp
#endif
tested_end:
    cmpl $0xDEAD0000, %esp
    jne fail
    cmpl $1, 0x2000
    jne fail
    movl 0x2004, %ecx
    cmpl $0xDEADFFF4, %ecx
    jne fail
    cmpl $_tested_end_off, %edi
    jne fail
    cmpl $0xFFFF4FF0, %esi
    jne fail
    movl $CASE, %ebx
    movl $1, %ebp
do_exit:
    movl $0x42, %eax
set_exit_port:
    movw $0xF4, %dx
do_out:
    outb %al, %dx
1:  hlt
    jmp 1b

db_handler:
    /* No stack instructions before capturing/checking the actual entry SP.
     * Absolute flat-DS reads remain valid even if an incorrect high half
     * reached the handler; never hide it via a second SP-only readback. */
    movl %esp, %ecx
    cmpl $0xDEADFFF4, %ecx
    jne fail
    movl %ecx, 0x2004
capture_ip:
    movl 0xFFF4, %edi
capture_cs:
    movl 0xFFF8, %edx
capture_flags:
    movl 0xFFFC, %ebp
capture_dr6:
    movl %dr6, %esi
    cmpl $_tested_end_off, %edi
    jne fail
    cmpl $8, %edx
    jne fail
    cmpl $0x102, %ebp
    jne fail
    cmpl $0xFFFF4FF0, %esi
    jne fail
    cmpl $0xA55A5AA5, 0xFFF0
    jne fail
    cmpl $0x5AA5A55A, 0
    jne fail
    incl 0x2000
clear_saved_tf:
    andl $~0x100, 0xFFFC
tested_iret:
    iret
fail:
    movl $0x43, %eax
    movw $0xF4, %dx
    outb %al, %dx
2:  hlt
    jmp 2b

    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA
    .word _start16_off
    .word 0xF000
    .fill 11, 1, 0
