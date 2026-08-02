/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * pdf — REVIEW_aug2 H-04: a fault DURING delivery must escalate to #DF.
 *
 * WHAT WAS WRONG
 * --------------
 * There was no delivery-depth state at all. start_fault() could re-vector an IDT
 * limit failure and S_INT_GATE could re-vector bad gate attributes, but each was a
 * documented "single re-vector", so a fault while delivering a fault simply started
 * another ordinary delivery. Measured on a real image (verif/sys/tests/ppriv, whose
 * IDT has only two gates): an undefined opcode produced
 *
 *     [FAULT] vec=6  err=00000000   #UD
 *     [FAULT] vec=11 err=00000032   IDT[6] not present  -> #NP  (6*8+2)
 *     [FAULT] vec=11 err=0000005A   IDT[11] not present -> #NP  (11*8+2)
 *     [FAULT] vec=11 err=0000005A   ... forever
 *
 * A real CPU raises #DF at the third and shuts down at the fourth. With the fix the
 * same image now produces exactly four faults and stops:
 *
 *     vec=6  depth=0    #UD, benign, delivered normally
 *     vec=11 depth=1    contributory, but the PREVIOUS one was benign -> no escalation
 *     vec=11 depth=1    contributory during contributory -> becomes #DF
 *     vec=11 depth=2    IDT[8] absent (err 0x42 = 8*8+2, i.e. the #DF delivery WAS
 *                       attempted) -> SHUTDOWN
 *
 * WHAT THIS TEST GRADES
 * ---------------------
 * Shutdown ends a trace, which is a weak thing to diff. This test instead grades the
 * case where #DF is actually DELIVERED and the handler runs:
 *
 *   IDT[8]  = df_handler, present.
 *   IDT[13] = a gate with P=0  (deliberately not present).
 *
 *   The mainline loads DS with selector 0x0080, which is past the GDT limit, so:
 *     #GP(0x80)                      -- contributory
 *       -> IDT[13] is not present    -- #NP(13*8+2 = 0x6A), also contributory
 *          -> contributory during contributory => #DF, error code 0
 *             -> df_handler runs at CPL0 and exits.
 *
 * The handler records the #DF error code, which IA-32 requires to be ZERO regardless
 * of what either contributing fault carried -- so "we escalated" and "we merely
 * delivered the second fault" are distinguishable by the pushed value, not just by
 * which handler ran. It also records the saved CS:EIP, which must point at the
 * ORIGINAL faulting instruction (the DS load), not at either handler.
 *
 * QEMU implements the full Table 6-5 escalation, so this is graded DIFFERENTIALLY.
 *
 * Layout follows pcpl: GDT @ 0x0500, IDT @ 0x1000, markers @ 0x2000.
 * NO paging, NO CPL3 -- everything here happens at CPL0, so the test isolates the
 * escalation itself from the privilege machinery.
 */

    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    /* GDT: null, code0 0x08, data0 0x10.  THREE entries only -- so selector 0x80 is
     * far past the limit and a load of it is a clean, deterministic #GP(0x80). */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)

    movw    $0x0017, 0x0480             /* GDT limit = 24-1 = 0x17 (3 entries) */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA
    .long   pm32_entry
    .word   0x08

    .code32
    .section .text32, "ax"
    .global pm32_entry
pm32_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp

    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $32, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000 --------------------------------------------------
     * vector 8  (#DF) -> df_handler, attr 0x8E  (P=1, DPL0, 32-bit int gate)
     * vector 13 (#GP) -> attr 0x0E              (P=0 -- DELIBERATELY ABSENT)
     * Everything else stays zero, which is also not-present; only these two
     * matter for the cascade below. */
    movl    $df_handler, %ebx
    movl    $0x00001040, %edi           /* 0x1000 + 8*8 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax           /* P=1 */
    movl    %eax, 4(%edi)

    /* vector 13: a well-formed 32-bit interrupt gate with P=0. Its target is the
     * same handler, so "the #GP gate was taken" and "the #GP gate was rejected as
     * not-present" cannot be confused by which code ran -- only P differs. */
    movl    $df_handler, %ebx
    movl    $0x00001068, %edi           /* 0x1000 + 13*8 */
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00000E00, %eax           /* P=0 -- NOT PRESENT */
    movl    %eax, 4(%edi)

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %ebp, %ebp

    /* ---- the trigger ---------------------------------------------------
     * Selector 0x80 is past the GDT limit (0x17), so this raises #GP(0x80).
     * Delivering it finds IDT[13] not present -> #NP, contributory during
     * contributory -> #DF. */
    .global trigger
trigger:
    movw    $0x0080, %ax
    movw    %ax, %ds                    /* #GP(0x80) -> #NP(0x6A) -> #DF(0) */

    /* Not reached: a correct machine never returns here. If the escalation is
     * missing and the second fault is merely delivered, control lands in
     * df_handler anyway -- which is exactly why the handler grades the ERROR CODE
     * and the saved EIP rather than merely its own existence. */
    movl    $0xBADBAD00, 0x00002030
hang0:
    jmp     hang0

    /* ---- df_handler: reached at CPL0 through IDT[8] ---------------------
     * Same-privilege delivery (the fault happened at CPL0), so the frame is
     *   [esp+ 0] error code   [esp+ 4] EIP   [esp+ 8] CS   [esp+12] EFLAGS
     * IA-32 requires #DF's error code to be ZERO. If the machine had instead just
     * delivered the #NP through this same gate, the pushed code would be 0x6A
     * (13*8+2) -- so the value decides which happened.                          */
    .align 16
    .global df_handler
df_handler:
    movl    0x00(%esp), %eax
    movl    %eax, 0x00002010            /* error code  (want 0x00000000 = #DF) */
    movl    0x04(%esp), %eax
    movl    %eax, 0x00002014            /* saved EIP   (want `trigger`+4, the DS load) */
    movl    0x08(%esp), %eax
    movl    %eax, 0x00002018            /* saved CS    (want 0x00000008) */
    incl    0x0000201C                  /* handler entry count (want 1) */

    /* report + exit. #DF is an ABORT: it is not restartable, so the handler does
     * not IRET -- it exits, which is also what makes the entry count meaningful. */
    movl    0x00002010, %ebx            /* EBX = #DF error code        (0) */
    movl    0x00002014, %ecx            /* ECX = saved EIP             (the DS load) */
    movl    0x00002018, %edx            /* EDX = saved CS              (0x08) */
    movl    0x0000201C, %esi            /* ESI = handler entries       (1) */
    movl    0x00002030, %edi            /* EDI = the not-reached marker (0 = never ran) */

    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
hang:
    hlt
    jmp     hang

    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
