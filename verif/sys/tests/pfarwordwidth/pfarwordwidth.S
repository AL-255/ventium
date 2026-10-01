/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Independent protected far-CALL/far-RET frame-width boundary witnesses.
 * CASE=1..32: bit0 RETF, bit1 paging, bit2 CS.D, bit3 SS.B, bit4 DWORD.
 * All code descriptors have base F0000 and limit FFFF: WORD return offsets
 * are genuine segment offsets, not truncated flat-ROM linear addresses.
 * CALL cases exit in the callee (no RETF dependency); RETF cases use a frame
 * seeded before paging (no far-CALL dependency). Any exception exits 135.
 */
#ifndef CASE
#define CASE 1
#endif
#if CASE < 1 || CASE > 32
#error CASE must be 1..32
#endif
#define OP_RETF (((CASE - 1) >> 0) & 1)
#define PAGED (((CASE - 1) >> 1) & 1)
#define CODE_D (((CASE - 1) >> 2) & 1)
#define STACK_B (((CASE - 1) >> 3) & 1)
#define DWORD_FRAME (((CASE - 1) >> 4) & 1)
#if DWORD_FRAME
#define FRAME_BYTES 4
#else
#define FRAME_BYTES 2
#endif
#if CODE_D
#define TEST_CS 8
#define A32
#else
#define TEST_CS 0x18
#define A32 addr32
#endif
#if PAGED
#define STACK_BASE 0x00400000
#define STACK_PHYS 0x00800000
#define STACK_TOP 0x1000
#else
#define STACK_BASE 0
#define STACK_PHYS 0
#define STACK_TOP 0x10000
#endif
#define FRAME_OFF (STACK_TOP - 2 * FRAME_BYTES)
#if STACK_B
#define HIGH_ESP 0
#define FINAL_SP STACK_TOP
#else
#define HIGH_ESP 0xDEAD0000
#define FINAL_SP (STACK_TOP & 0xFFFF)
#endif
#if OP_RETF
#define EXPECTED_ESP (HIGH_ESP | FINAL_SP)
#else
#define EXPECTED_ESP (HIGH_ESP | FRAME_OFF)
#endif

    .global case_id, operation_kind, boundary_kind, code_d, stack_b
    .global frame_bytes, expected_esp, expected_frame_cs, expected_ss
    .global frame_ip_lin, frame_cs_lin, guard_before_lin
    .set case_id, CASE
    .set operation_kind, OP_RETF
    .set boundary_kind, PAGED
    .set code_d, CODE_D
    .set stack_b, STACK_B
    .set frame_bytes, FRAME_BYTES
    .set expected_esp, EXPECTED_ESP
    .set expected_frame_cs, TEST_CS
    .set expected_ss, 0x20
    .set frame_ip_lin, STACK_BASE + FRAME_OFF
    .set frame_cs_lin, STACK_BASE + FRAME_OFF + FRAME_BYTES
    .set guard_before_lin, STACK_BASE + FRAME_OFF - 4

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

    /* GDT: null, ROM code32, flat data32, ROM code16, bounded test SS.
     * Accessed bits are pre-set so descriptor-writeback differences cannot
     * accidentally become the observation being tested. */
    movl $0, 0x500
    movl $0, 0x504
    movl $0x0000FFFF, 0x508
    movl $0x00409B0F, 0x50C
    movl $0x0000FFFF, 0x510
    movl $0x00CF9300, 0x514
    movl $0x0000FFFF, 0x518
    movl $0x00009B0F, 0x51C
    movl $0x0000FFFF, 0x520
    movl $((STACK_B << 22) | 0x9300 | (STACK_BASE >> 16)), 0x524
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
    .global pm32_entry, fault_fail32
pm32_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %fs
    movw %ax, %gs
    movl $0x9000, %esp
    movl $0, 0x2000
    xorl %eax, %eax
    movl %eax, %cr2
    movl %eax, %cr3
    /* Same-privilege 32-bit fault gates. Handlers never return or use the
     * questionable frame. Its downward exception pushes remain in range. */
    movl $0x1000, %edi
    movl $16, %ecx
1:  movl $_fault_gate_low, (%edi)
    movl $0x00008E00, 4(%edi)
    addl $8, %edi
    loop 1b
    movw $0x7F, 0x490
    movl $0x1000, 0x492
    lidt 0x490

    /* Seed the entire frame and adjacent controls via flat DS, before PG.
     * CALL must overwrite both slots; RETF must consume exactly these slots. */
    movl $0xA55A5AA5, (STACK_PHYS + FRAME_OFF - 4)
    movl $0x5AA5A55A, (STACK_PHYS + STACK_TOP)
#if OP_RETF
#if DWORD_FRAME
    movl $_retf_resume_off, (STACK_PHYS + FRAME_OFF)
    movl $TEST_CS, (STACK_PHYS + FRAME_OFF + FRAME_BYTES)
#else
    movw $_retf_resume_off, (STACK_PHYS + FRAME_OFF)
    movw $TEST_CS, (STACK_PHYS + FRAME_OFF + FRAME_BYTES)
#endif
#else
    movl $0xBAD0BAD0, (STACK_PHYS + FRAME_OFF)
#if DWORD_FRAME
    movl $0xBAD1BAD1, (STACK_PHYS + FRAME_OFF + FRAME_BYTES)
#endif
#endif

#if PAGED
    /* Fresh, explicit page tables. PT0 maps the low 1MiB identity; PT1 has
     * only its first entry. Thus linear 401000 really is non-present even
     * though the adjacent PHYSICAL page contains the guard sentinel. */
    movl $0x11000, %edi
    movl $3072, %ecx
    xorl %eax, %eax
    rep stosl
    movl $0x12003, 0x11000
    movl $0x13003, 0x11004
    movl $0x12000, %edi
    movl $0x00000003, %eax
    movl $256, %ecx
2:  movl %eax, (%edi)
    addl $0x1000, %eax
    addl $4, %edi
    loop 2b
    movl $0x00800003, 0x13000
    movl $0x11000, %eax
    movl %eax, %cr3
    movl %cr0, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0
#endif
    movw $0x20, %ax
    movw %ax, %ss
#if OP_RETF
    movl $(HIGH_ESP | FRAME_OFF), %esp
#else
    movl $(HIGH_ESP | FINAL_SP), %esp
#endif
    .byte 0xEA
    .long _tested_entry_off
    .word TEST_CS

fault_fail32:
    incl 0x2000
    movl $0x43, %eax
    movw $0xF4, %dx
    outb %al, %dx
3:  hlt
    jmp 3b

    .section .textcase,"ax"
#if CODE_D
    .code32
#else
    .code16
#endif
    .global tested_entry, tested_op, call_resume, retf_resume, callee
    .global do_exit, set_exit_port, do_out
    .global capture_load_ip, capture_load_cs, capture_guard_before
    .global capture_guard_after, capture_fault_count
tested_entry:
    /* The instruction alone changes the stack. No PUSH/POP staging occurs
     * after test SS is installed, and the CALL and RETF halves are separate. */
tested_op:
#if (FRAME_BYTES == 2 && CODE_D == 1) || (FRAME_BYTES == 4 && CODE_D == 0)
    .byte 0x66
#endif
#if OP_RETF
    .byte 0xCB
#else
    .byte 0x9A
#if DWORD_FRAME
    .long _callee_off
#else
    .word _callee_off
#endif
    .word TEST_CS
#endif
call_resume:
    jmp fail
retf_resume:
    jmp capture
callee:
    /* No RETF here: a CALL-only success cannot hide behind a return fix. */
capture:
    movl %esp, %ecx
    cmpl $EXPECTED_ESP, %ecx
    jne fail
#if DWORD_FRAME
capture_load_ip:
    A32 movl (STACK_BASE + FRAME_OFF), %esi
capture_load_cs:
    A32 movl (STACK_BASE + FRAME_OFF + FRAME_BYTES), %edi
#else
capture_load_ip:
    A32 movzwl (STACK_BASE + FRAME_OFF), %esi
capture_load_cs:
    A32 movzwl (STACK_BASE + FRAME_OFF + FRAME_BYTES), %edi
#endif
#if OP_RETF
    cmpl $_retf_resume_off, %esi
#else
    cmpl $_call_resume_off, %esi
#endif
    jne fail
    cmpl $TEST_CS, %edi
    jne fail
capture_guard_before:
    A32 cmpl $0xA55A5AA5, (STACK_BASE + FRAME_OFF - 4)
    jne fail
#if PAGED
    /* Do NOT read the absent virtual page as a witness! Check its PTE only. */
capture_guard_after:
    A32 cmpl $0, 0x13004
#else
capture_guard_after:
    A32 cmpl $0x5AA5A55A, STACK_TOP
#endif
    jne fail
capture_fault_count:
    A32 movl 0x2000, %ebp
    testl %ebp, %ebp
    jne fail
    movl $CASE, %ebx
    xorl %edx, %edx
do_exit:
    movl $0x42, %eax
set_exit_port:
    movw $0xF4, %dx
do_out:
    outb %al, %dx
4:  hlt
    jmp 4b
fail:
    movl $0x43, %eax
    movw $0xF4, %dx
    outb %al, %dx
5:  hlt
    jmp 5b

    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA
    .word _start16_off
    .word 0xF000
    .fill 11, 1, 0
