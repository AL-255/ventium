/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Same-privilege INT3: interrupt-gate operand size is independent of SS.B.
 * CASE bits: bit0 WORD gate; bit1 SS.B32; bit2 SP-wrap/control placement.
 * B=0 uses ESP high DEAD and SP=1000 or 0000; B=1 uses ESP=1000 or10000.
 * Handlers read the actual frame through flat DS before any PUSH/POP.
 */
#ifndef CASE
#define CASE 1
#endif
#if CASE < 1 || CASE > 8
#error CASE must be 1..8
#endif
#define WORD_GATE ((CASE - 1) & 1)
#define STACK_B (((CASE - 1) >> 1) & 1)
#define WRAP_PLACEMENT (((CASE - 1) >> 2) & 1)
#if WORD_GATE
#define SLOT_BYTES 2
#define GATE_ATTR 0x8600
#else
#define SLOT_BYTES 4
#define GATE_ATTR 0x8E00
#endif
#if WRAP_PLACEMENT
#if STACK_B
#define INITIAL_SP 0x10000
#else
#define INITIAL_SP 0
#endif
#else
#define INITIAL_SP 0x1000
#endif
#if STACK_B
#define HIGH_ESP 0
#define FRAME_OFF (INITIAL_SP - 3 * SLOT_BYTES)
#else
#define HIGH_ESP 0xDEAD0000
#define FRAME_OFF ((INITIAL_SP - 3 * SLOT_BYTES) & 0xFFFF)
#endif
#define INITIAL_ESP (HIGH_ESP | INITIAL_SP)
#define HANDLER_ESP (HIGH_ESP | FRAME_OFF)
#define FRAME_CS_OFF (FRAME_OFF + SLOT_BYTES)
#define FRAME_FLAGS_OFF (FRAME_OFF + 2 * SLOT_BYTES)

    .global case_id, word_gate, stack_b, wrap_placement, slot_bytes
    .global initial_esp, handler_esp, frame_ip_lin, frame_cs_lin, frame_flags_lin
    .global guard_before_lin, guard_after_lin, expected_frame_flags
    .set case_id, CASE
    .set word_gate, WORD_GATE
    .set stack_b, STACK_B
    .set wrap_placement, WRAP_PLACEMENT
    .set slot_bytes, SLOT_BYTES
    .set initial_esp, INITIAL_ESP
    .set handler_esp, HANDLER_ESP
    .set frame_ip_lin, FRAME_OFF
    .set frame_cs_lin, FRAME_CS_OFF
    .set frame_flags_lin, FRAME_FLAGS_OFF
    .set guard_before_lin, FRAME_OFF - 4
    .set guard_after_lin, INITIAL_SP
    .set expected_frame_flags, 0xCD7

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
    movl $((STACK_B << 22) | 0x9300), 0x524
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
    .global pm32_entry, tested_int3, int3_end, frame_handler
    .global tested_iret, capture_ip, capture_cs, capture_flags
    .global do_exit, set_exit_port, do_out, fail
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
    movl $0, 0x2000
    movl $0, 0x2004
    movl $_frame_gate_low, 0x3018
    movl $GATE_ATTR, 0x301C
    movw $0x1F, 0x490
    movl $0x3000, 0x492
    lidt 0x490
    movl $0xA55A5AA5, (FRAME_OFF - 4)
    movl $0x5AA5A55A, INITIAL_SP
    movl $0xBAD0BAD0, FRAME_OFF
    /* A WORD frame's six bytes are seeded without touching its guard. */
#if WORD_GATE
    movw $0xBAD1, FRAME_CS_OFF
    movw $0xBAD2, FRAME_FLAGS_OFF
#else
    movl $0xBAD1BAD1, FRAME_CS_OFF
    movl $0xBAD2BAD2, FRAME_FLAGS_OFF
#endif
    pushl $0xCD5
    popfl
    movw $0x20, %ax
    movw %ax, %ss
    movl $INITIAL_ESP, %esp
tested_int3:
    int3
int3_end:
    cmpl $INITIAL_ESP, %esp
    jne fail
    cmpl $1, 0x2000
    jne fail
    movl 0x2004, %ecx
    cmpl $HANDLER_ESP, %ecx
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

frame_handler:
    movl %esp, %ecx
    cmpl $HANDLER_ESP, %ecx
    jne fail
    movl %ecx, 0x2004
#if WORD_GATE
capture_ip:
    movzwl FRAME_OFF, %esi
capture_cs:
    movzwl FRAME_CS_OFF, %edi
capture_flags:
    movzwl FRAME_FLAGS_OFF, %ebp
#else
capture_ip:
    movl FRAME_OFF, %esi
capture_cs:
    movl FRAME_CS_OFF, %edi
capture_flags:
    movl FRAME_FLAGS_OFF, %ebp
#endif
    cmpl $_int3_end_off, %esi
    jne fail
    cmpl $8, %edi
    jne fail
    cmpl $0xCD7, %ebp
    jne fail
    cmpl $0xA55A5AA5, (FRAME_OFF - 4)
    jne fail
    cmpl $0x5AA5A55A, INITIAL_SP
    jne fail
    incl 0x2000
tested_iret:
#if WORD_GATE
    .byte 0x66
#endif
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
