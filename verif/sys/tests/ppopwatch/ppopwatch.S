/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * POP memory write-watchpoint provenance, independent of ESP-based EA rules.
 * CASE1: FS:[EBX], DWORD; CASE2: based DS:[EBX], WORD;
 * CASE3: ordinary SS-default [EBP], DWORD; CASE4: FS:[EBX], unwatched.
 * SS is flat/B=1 in every case. No paging, TF, guest patches or fault filters.
 */
#ifndef CASE
#define CASE 1
#endif
#if CASE < 1 || CASE > 4
#error CASE must be 1..4
#endif
#if CASE == 2
#define DEST_LINEAR 0x24000
#define DEST_VALUE 0xD00D1122
#define DR7_VALUE 0x00050401
#define POP_WIDTH 2
#else
#if CASE == 3
#define DEST_LINEAR 0x4000
#else
#define DEST_LINEAR 0x14000
#endif
#define DEST_VALUE 0x11223344
#define DR7_VALUE 0x000D0401
#define POP_WIDTH 4
#endif
#if CASE == 4
#define WATCH_LINEAR 0x4000
#define HANDLERS 0
#define DR6_VALUE 0xFFFF0FF0
#define CAPTURED_ESP 0x7000
#else
#define WATCH_LINEAR DEST_LINEAR
#define HANDLERS 1
#define DR6_VALUE 0xFFFF0FF1
#define CAPTURED_ESP 0x6FF4
#endif
    .global case_id, destination_linear, watch_linear, expected_value
    .global operand_width, expected_handlers, expected_dr6, captured_esp
    .global postpop_esp, expected_saved_flags
    .set case_id, CASE
    .set destination_linear, DEST_LINEAR
    .set watch_linear, WATCH_LINEAR
    .set expected_value, DEST_VALUE
    .set operand_width, POP_WIDTH
    .set expected_handlers, HANDLERS
    .set expected_dr6, DR6_VALUE
    .set captured_esp, CAPTURED_ESP
    .set postpop_esp, 0x7000
    .set expected_saved_flags, 2

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
    movl $0x00CF9B00, 0x50C       /* CS8: flat, D=1 */
    movl $0x0000FFFF, 0x510
    movl $0x00CF9300, 0x514       /* SS/DS10: flat, B=1 */
    movl $0x0000FFFF, 0x518
    movl $0x00409301, 0x51C       /* FS18: base10000, limitFFFF */
    movl $0x0000FFFF, 0x520
    movl $0x00409302, 0x524       /* DS20: base20000, limitFFFF */
    movw $0x27, 0x480
    movl $0x500, 0x482
    lgdt 0x480
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    .byte 0x66, 0xEA
    .long pm32_entry
    .word 8

    .code32
    .section .text32,"ax"
    .global pm32_entry, tested_op, tested_end, db_handler
    .global capture_ip, capture_cs, capture_flags, capture_dr6, tested_iret
    .global do_exit, set_exit_port, do_out, fail
pm32_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %gs
    movw $0x18, %ax
    movw %ax, %fs
    movl $0x7000, %esp
    xorl %eax, %eax
    movl %eax, %cr2
    movl %eax, %cr3
    movl $0x400, %eax
    movl %eax, %dr7
    movl $0xFFFF0FF0, %eax
    movl %eax, %dr6
    movl $0, %ss:0x2000
    movl $0xD00D0000, %ss:DEST_LINEAR
    movl $_db_gate_low, %ss:0x3008
    movl $_db_gate_high, %ss:0x300C
    movw $0xF, %ss:0x490
    movl $0x3000, %ss:0x492
    lidt %ss:0x490
#if CASE == 2
    movw $0x20, %ax
    movw %ax, %ds
#endif
    movl $0, %eax
    movl $0x4000, %ebx
    movl $0, %ecx
    movl $0, %edx
    movl $0, %esi
    movl $0, %edi
    movl $0x4000, %ebp
    pushl $2
    popfl                         /* TF/IF/RF all clear, exact saved FLAGS2 */
#if CASE == 2
    pushw $0x1122
#else
    pushl $0x11223344
#endif
    movl $WATCH_LINEAR, %eax
    movl %eax, %dr0
    movl $DR7_VALUE, %eax
    movl %eax, %dr7
tested_op:
#if CASE == 2
    popw (%ebx)
#elif CASE == 3
    popl (%ebp)
#else
    popl %fs:(%ebx)
#endif
tested_end:
    cmpl $0x7000, %esp
    jne fail
    cmpl $HANDLERS, %ss:0x2000
    jne fail
    cmpl $DEST_VALUE, %ss:DEST_LINEAR
    jne fail
#if CASE == 4
    movl %dr6, %esi
    cmpl $DR6_VALUE, %esi
    jne fail
    movl %esp, %ecx
    movl $0x400, %eax
    movl %eax, %dr7
#else
    cmpl $tested_end, %edi
    jne fail
    cmpl $DR6_VALUE, %esi
    jne fail
#endif
    movl $CASE, %ebx
    movl $HANDLERS, %ebp
do_exit:
    movl $0x42, %eax
set_exit_port:
    movw $0xF4, %dx
do_out:
    outb %al, %dx
1:  hlt
    jmp 1b

db_handler:
#if CASE == 4
    jmp fail                      /* A wrong old-SS watchpoint must NOT fire */
#endif
    movl %esp, %ecx
    cmpl $0x6FF4, %ecx             /* POP completed before DWORD trap frame */
    jne fail
capture_ip:
    movl %ss:0(%esp), %edi
capture_cs:
    movl %ss:4(%esp), %edx
capture_flags:
    movl %ss:8(%esp), %ebp
capture_dr6:
    movl %dr6, %esi
    movl $0x400, %eax
    movl %eax, %dr7                /* Disarm before returning */
    cmpl $tested_end, %edi
    jne fail
    cmpl $8, %edx
    jne fail
    cmpl $2, %ebp
    jne fail
    cmpl $DR6_VALUE, %esi
    jne fail
    cmpl $DEST_VALUE, %ss:DEST_LINEAR /* Data already committed at trap entry */
    jne fail
    incl %ss:0x2000
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
