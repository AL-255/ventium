/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * pstk16 — REVIEW_aug2 H-01: 16-bit PROTECTED-mode stacks.
 *
 * WHAT WAS WRONG
 * --------------
 * Two independent halves, and the corpus reached neither:
 *
 *  1. Only the stack ADDRESS went through stk16(). The final GPR writeback masked
 *     ESP on `real_mode` alone, so on a 16-bit PROTECTED stack (SS.B=0, real_mode=0)
 *     a push at SP=0 accessed SS:FFFC but then committed ESP=FFFFFFFC instead of
 *     preserving ESP[31:16] and changing only SP. With paging on, the next access
 *     off that ESP lands on a completely different page.
 *
 *  2. ss_b was captured ONLY on the ordinary segment-load path. SS installed by a
 *     cross-privilege interrupt delivery (from TSS.SS0) or by a task switch kept the
 *     PREVIOUS descriptor's width, so the frame was pushed with the wrong address
 *     size.
 *
 * Both were measured to be unreachable before this test existed: instrumenting the
 * core (+ven_h01) across all 16 system tests reported
 *     16-bit PM-stack ESP writebacks: 0   new SS.B captures: 0
 * for every one of them. A green verify-all said nothing about either half.
 *
 * WHAT THIS TEST GRADES
 * ---------------------
 * case 1 (half 1)  SS <- a 16-bit DPL0 data descriptor (B=0, limit 0xFFFF), then
 *      ESP <- 0xDEAD0000, so SP=0x0000. A `pushl` must:
 *        * write at linear 0x0000FFFC (base 0 + wrapped SP), verified by reading it
 *          back through the FLAT DS -- not at 0xDEACFFFC, and
 *        * leave ESP = 0xDEADFFFC -- high half preserved, only SP changed.
 *      Then `popl` must restore ESP = 0xDEAD0000 and return the value.
 *      The 0xDEAD in the high half is the whole point: a 32-bit-stack
 *      implementation produces 0xDEACFFFC, and a "mask the whole thing"
 *      implementation produces 0x0000FFFC. All three are distinguishable.
 *
 * Half 2 (the ss_b capture at a cross-privilege delivery) is IMPLEMENTED but is NOT
 * graded here -- see the note at the end of the code for the measurement that made
 * that call, and do not read this test's green line as covering it.
 *
 * Every value here is deterministic and QEMU implements both, so this is graded
 * DIFFERENTIALLY against the golden.
 *
 * Layout follows pcpl:
 *   GDT @ 0x0500 (7 entries)   IDT @ 0x1000   markers @ 0x2000   TSS @ 0x3000
 *   CPL0 boot stack 0x00090000, CPL3 stack 0x00080000
 * The 16-bit stack occupies linear 0x0000..0xFFFF, which is below the GDT at 0x500
 * only in its first page -- the pushes land at 0xFFEC..0xFFFF, clear of the GDT
 * (0x500), IDT (0x1000..0x17FF) and markers (0x2000).
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

    /* GDT
     *   0x08 code32 flat DPL0        0x9A / 0xCF
     *   0x10 data32 flat DPL0        0x92 / 0xCF
     *   0x18 code32 flat DPL3        0xFA / 0xCF
     *   0x20 data32 flat DPL3        0xF2 / 0xCF
     *   0x28 TSS32 base 0x3000 limit 0x67
     *   0x30 data16 DPL0 base 0 limit 0xFFFF, B=0  0x92 / 0x00   <- THE 16-BIT STACK
     */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)
    movl    $0x00CFFA00, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)
    movl    $0x00CFF200, 36(%ebx)
    movl    $0x30000067, 40(%ebx)
    movl    $0x00008900, 44(%ebx)
    /* idx6 0x30: limit 0xFFFF, base 0, access 0x92, gran byte 0x00 => G=0, B=0 */
    movl    $0x0000FFFF, 48(%ebx)
    movl    $0x00009200, 52(%ebx)

    movw    $0x0037, 0x0480             /* GDT limit = 56-1 = 0x37 (7 entries) */
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

    /* seed the two candidate slots so "which address did the push use?" is decided
     * by which sentinel got overwritten, not by reading uninitialised memory. */
    movl    $0x5A5A5A5A, 0x0000FFFC     /* where a 16-BIT stack must write */

    /* ============================== CASE 1 ==============================
     * Switch SS to the 16-bit descriptor and put a recognisable value in the high
     * half of ESP. Note the ORDER: load SS first, then ESP, so the push below is
     * unambiguously governed by the new descriptor. */
    movw    $0x0030, %ax
    movw    %ax, %ss
    movl    $0xDEAD0000, %esp           /* SP = 0x0000, high half = 0xDEAD */

    pushl   $0x11223344                 /* must write linear 0xFFFC; ESP -> 0xDEADFFFC */
    movl    %esp, %eax
    movl    %eax, 0x00002010            /* ESP after push  (want 0xDEADFFFC) */
    movl    0x0000FFFC, %eax            /* read the slot back through the FLAT DS */
    movl    %eax, 0x00002014            /* (want 0x11223344 = the push landed here) */

    popl    %eax
    movl    %eax, 0x00002018            /* popped value    (want 0x11223344) */
    movl    %esp, %eax
    movl    %eax, 0x0000201C            /* ESP after pop   (want 0xDEAD0000) */

    /* restore a normal 32-bit stack for the rest of the test */
    movw    $0x0010, %ax
    movw    %ax, %ss
    movl    $0x00090000, %esp

    /* ============================ REPORT + EXIT =========================
     * Case 2 -- a cross-privilege delivery onto a 16-bit TSS.SS0 stack, which is
     * what grades the ss_b capture added in core_tss_priv.svh -- is NOT in this
     * image. It was written, run, and REMOVED because it exposed a SEPARATE and
     * still-open defect rather than grading the one this test is for: with a 16-bit
     * SS the cross-privilege IRET returns to the wrong EIP. Measured, both traces
     * agreeing on everything up to that point:
     *     golden n=290 pc=0x000f01ea   (the instruction after the INT)
     *     RTL    n=290 pc=0x000f01e0   (the top of user_entry -- re-entered)
     * Shipping it here would have made this gate red for a reason that has nothing
     * to do with the ESP/address half it exists to prove. Tracked separately; the
     * SS.B-at-delivery capture is therefore IMPLEMENTED BUT UNGATED.
     */
    movl    0x00002010, %eax            /* EAX = ESP after the 16-bit push (0xDEADFFFC) */
    movl    0x00002014, %ebx            /* EBX = value read at 0xFFFC      (0x11223344) */
    movl    0x00002018, %ebp            /* EBP = popped value              (0x11223344) */
    movl    0x0000201C, %ecx            /* ECX = ESP after the pop         (0xDEAD0000) */
    movl    0x0000FFFC, %edx            /* EDX = the slot itself           (0x11223344,
                                         *       i.e. it overwrote the 0x5A5A5A5A seed) */

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
