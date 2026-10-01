/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * First two independent POP-memory ESP-base witnesses. More directed
 * variants will be added without changing the already frozen first images.
 * CASE1 exactly 67 66 8f 44 24 08;66 cb in CS16, SS.B0.
 * CASE2 independent CS32 sentinel, SS.B1, no RETF dependency.
 */
#ifndef CASE
#define CASE 1
#endif
#if CASE > 2
#include "ppopespea_corners.S"
#else
#if CASE < 1 || CASE > 2
#error CASE must initially be1 or2
#endif
#if CASE == 1
#define TEST_CS 0x18
#define STACK_B 0
#define A32 addr32
#define FINAL_ESP 0x200c
#else
#define TEST_CS 8
#define STACK_B 1
#define A32
#define FINAL_ESP 0x2004
#endif
#define VALUE 0x13579bdf
    .global case_id, expected_esp, pop_esp, destination_lin, source_lin, expected_value, expected_cs
    .set case_id, CASE
    .set expected_esp, FINAL_ESP
    .set pop_esp, 0x2004
    .set destination_lin, 0x200c
    .set source_lin, 0x2000
    .set expected_value, VALUE
    .set expected_cs, TEST_CS
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
    movl $0x00409b0f,0x50c
    movl $0x0000ffff,0x510
    movl $0x00cf9300,0x514
    movl $0x0000ffff,0x518
    movl $0x00009b0f,0x51c
    movl $0x0000ffff,0x520
    movl $(0x008f9300 | (STACK_B << 22)),0x524
    movw $0x27,0x480
    movl $0x500,0x482
    lgdt 0x480
    movl %cr0,%eax
    orl $1,%eax
    movl %eax,%cr0
    .byte 0x66,0xea
    .long _pm32_off
    .word 8
    .code32
    .section .text32,"ax"
    .global pm32_entry, fault_fail, fault_handler
    .set fault_handler, fault_fail
pm32_entry:
    movw $0x10,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw %ax,%fs
    movw %ax,%gs
    movl $0x9000,%esp
    xorl %eax,%eax
    movl %eax,%cr2
    movl %eax,%cr3
    movl $0,0x2100
    movl $0x3000,%edi
    movl $16,%ecx
1:  movl $_fault_gate_low,(%edi)
    movl $0x00008e00,4(%edi)
    addl $8,%edi
    loop 1b
    movw $0x7f,0x490
    movl $0x3000,0x492
    lidt 0x490
    movl $VALUE,0x2000
    movl $_after_retf_off,0x2004
    movl $TEST_CS,0x2008
    movl $0xa55a5aa5,0x200c
    movl $0x5aa5a55a,0x2010
    pushl $2
    popfl
    movw $0x20,%ax
    movw %ax,%ss
    movl $0x2000,%esp
    movl $0x11223344,%eax
    .byte 0xea
    .long _tested_entry_off
    .word TEST_CS
fault_fail:
    incl 0x2100
    movl $0x43,%eax
    movw $0xf4,%dx
    outb %al,%dx
2:  hlt
    jmp 2b
    .section .textcase,"ax"
#if CASE == 1
    .code16
#else
    .code32
#endif
    .global tested_entry, tested_pop, pop_end, tested_retf, after_retf
    .global capture_esp, capture_destination, capture_source, do_exit, set_exit_port, do_out, fail
tested_entry:
tested_pop:
#if CASE == 1
    .byte 0x67,0x66,0x8f,0x44,0x24,0x08
#else
    .byte 0x8f,0x44,0x24,0x08
#endif
pop_end:
tested_retf:
#if CASE == 1
    .byte 0x66,0xcb
#else
    jmp after_retf
#endif
after_retf:
capture_esp:
    movl %esp,%ecx
    cmpl $FINAL_ESP,%ecx
    jne fail
capture_destination:
    A32 movl 0x200c,%esi
    cmpl $VALUE,%esi
    jne fail
capture_source:
    A32 movl 0x2000,%edi
    cmpl $VALUE,%edi
    jne fail
    A32 cmpl $0x5aa5a55a,0x2010
    jne fail
    A32 movl 0x2100,%ebp
    testl %ebp,%ebp
    jne fail
    movl $CASE,%ebx
do_exit:
    movl $0x42,%eax
set_exit_port:
    movw $0xf4,%dx
do_out:
    outb %al,%dx
3:  hlt
    jmp 3b
fail:
    movl $0x43,%eax
    movw $0xf4,%dx
    outb %al,%dx
4:  hlt
    jmp 4b
    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xea
    .word _start16_off
    .word 0xf000
    .fill 11,1,0
#endif
