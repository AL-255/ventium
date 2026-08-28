/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug3 C-04 — a far CALL to an AVAILABLE 32-bit TSS is a NESTING task
 * switch, not a JMP task switch.
 *
 * The defect: a protected far CALL sets lcall_pend and enters the shared S_LJMP
 * state, but the 32-bit-TSS system-descriptor branch ran before the lcall_pend
 * code-segment branch, so a legal `lcall $TSS2,$0` executed the JMP task-switch
 * form: it did NOT write the incoming TSS back-link, did NOT set NT in the
 * incoming EFLAGS image, and CLEARED the outgoing TSS's busy bit. Those
 * semantics are observably different from a JMP and they break nested-task
 * return: with no back-link and no NT, an IRET from the "nested" task is an
 * ordinary return, and with the outgoing TSS marked available the caller task
 * has silently become re-enterable. The fix latches the transfer kind
 * (tsw_call): S_TSW_BUSY writes the outgoing TR selector into the incoming
 * TSS's back-link field (offset 0), leaves the OUTGOING descriptor BUSY (0x8B),
 * and the commit sets EFLAGS.NT (bit 14) in the incoming task.
 *
 * ptask proves the JMP form (no NT/back-link, outgoing busy cleared). This test
 * is its CALL twin. Memory plan, GDT and the TSS images deliberately mirror
 * ptask so the ONLY architectural difference is JMP vs CALL intent:
 *
 *   GDT  @ 0x00000500   null + code0 0x08 + data0 0x10 + filler 0x18
 *                       + TSS1 0x20 (base 0x3000) + TSS2 0x28 (base 0x4000),
 *                       both 32-bit AVAILABLE TSS (access 0x89, limit 0x67)
 *   markers @ 0x00002000
 *   TSS1 @ 0x00003000   (current task; LTR'd; CPU saves outgoing state here)
 *   TSS2 @ 0x00004000   (target task; pre-initialised state image)
 *   task1 stack @ 0x00090000 ; task2 stack @ 0x00070000
 *
 * WITNESSES (all in the marker page, read back into GPRs at the exit so the
 * golden-vs-RTL differential compares them; QEMU implements the nesting switch
 * and is the oracle):
 *   0x2030  TSS2 back-link word (TSS2+0) after the CALL == 0x0020, the OUTGOING
 *           TR selector. 0 (or anything else) = no back-link was written (the
 *           JMP form ran).
 *   0x2034  task2's EFLAGS with NT (bit 14) SET -- the incoming image gains NT
 *           across a CALL task switch. A JMP form leaves NT clear.
 *   0x2038  (TSS1_access<<8)|TSS2_access == 0x8B8B -- BOTH descriptors busy
 *           after the CALL: the outgoing STAYS busy (it is an active suspended
 *           task), the incoming becomes busy. The JMP form gives 0x898B.
 *   0x203C  1 iff TSS1 saved EIP == task1_resumed, the instruction AFTER the
 *           lcall -- the outgoing save recorded the correct resume point.
 *   0x2040  the raw TSS1 saved EIP (nonzero; equals task1_resumed).
 *   0x2044  TSS1 saved EAX == 0x1A1A1A1A (the live EAX at the lcall) -- the
 *           outgoing GPR save captured the live register.
 *   0x2010  0x99999999 -- control RETURNED to task1 at task1_resumed: task2's
 *           IRET ran with NT=1, which task-switches back through TSS2's
 *           back-link (the word the CALL wrote).
 *   0x2014  task1's EFLAGS after the return -- NT CLEAR again (the saved image
 *           had NT=0; the CALL only set NT in the INCOMING task).
 *   0x2018  (TSS1_access<<8)|TSS2_access == 0x8B89 after the NT-IRET: the
 *           incoming (TSS1) stays busy, the IRET cleared the outgoing (TSS2).
 *
 * NEGATIVE CONTROL (REQUIRED, see manifest.json): against the HEAD TB (no fix)
 * the CALL runs the JMP form -- back-link never written, NT never set, outgoing
 * busy cleared -- so the golden diff diverges (measured: first divergence at
 * task2's back-link/NT witnesses; without NT task2's IRET pops garbage as an
 * ordinary return and never reaches task1_resumed).
 *
 * NO paging (linear == physical); the PAGED task-switch variant is ptaskpg.
 * Flat 64 KiB -bios image; reset F000:FFF0. GNU-as syntax; no nasm.
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

    /* --- build the GDT (6 entries = 48 bytes) at linear 0x0500 ---
     * idx0 null
     * idx1 0x08 code32 flat DPL0   (access 0x9A, gran 0xCF)
     * idx2 0x10 data32 flat DPL0   (access 0x92, gran 0xCF)
     * idx3 0x18 data32 flat (filler)
     * idx4 0x20 TSS1 (available, base 0x3000, limit 0x67, access 0x89)
     * idx5 0x28 TSS2 (available, base 0x4000, limit 0x67, access 0x89)
     */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* idx3 0x18 filler data32 */
    movl    $0x00CF9200, 28(%ebx)
    /* idx4 0x20 TSS1: base 0x00003000, limit 0x67, access 0x89 (32-bit avail TSS) */
    movl    $0x30000067, 32(%ebx)
    movl    $0x00008900, 36(%ebx)
    /* idx5 0x28 TSS2: base 0x00004000, limit 0x67, access 0x89 */
    movl    $0x40000067, 40(%ebx)
    movl    $0x00008900, 44(%ebx)

    movw    $0x002F, 0x0480             /* GDT limit = 48-1 = 0x2F (6 entries) */
    movl    $0x00000500, 0x0482         /* GDT base = 0x0500 */
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                  /* opsize-32 ljmp ptr16:32 */
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
    movl    $0x00090000, %esp           /* task1 (current) stack */

    /* --- zero the marker area at 0x2000..0x2050 --- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $20, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* zero TSS1 (the outgoing-save target); TSS2 is field-initialised below and
     * low RAM resets to 0 (same convention as ptask). */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $52, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movw    $0x0068, 0x00003066         /* TSS1 I/O map base (empty) */

    /* ===================== pre-init TSS2 (the incoming task) ============== *
     * 32-bit TSS field offsets (base 0x4000):
     *   0x00 BACKLINK  0x1C CR3   0x20 EIP     0x24 EFLAGS  0x28 EAX  0x34 EBX
     *   0x38 ESP       0x48 ES    0x4C CS      0x50 SS      0x54 DS   0x58 FS
     *   0x5C GS        0x60 LDTR  0x66 IOmapbase                              */
    movl    $0x00000000, 0x0000401C     /* CR3 = 0 (paging off) */
    movl    $task2,      0x00004020     /* EIP = task2 */
    movl    $0x00000002, 0x00004024     /* EFLAGS = 0x2 (NT CLEAR in the image --
                                         * the CALL itself must SET it) */
    movl    $0xAAAAAAAA, 0x00004028     /* EAX marker (reload proof) */
    movl    $0xBBBBBBBB, 0x00004034     /* EBX marker (reload proof) */
    movl    $0x00070000, 0x00004038     /* ESP = task2 stack top */
    movl    $0x00000010, 0x00004048     /* ES = 0x10 */
    movl    $0x00000008, 0x0000404C     /* CS = 0x08 */
    movl    $0x00000010, 0x00004050     /* SS = 0x10 */
    movl    $0x00000010, 0x00004054     /* DS = 0x10 */
    movl    $0x00000010, 0x00004058     /* FS = 0x10 */
    movl    $0x00000010, 0x0000405C     /* GS = 0x10 */
    movl    $0x00000000, 0x00004060     /* LDTR = 0 (no LDT) */
    movw    $0x0068,     0x00004066     /* I/O map base (empty) */
    /* TSS2 back-link (0x4000) stays 0: the CALL must WRITE it. */

    /* LTR TSS1 (selector 0x20): TR now points at the CURRENT task = TSS1. */
    movw    $0x0020, %ax
    ltr     %ax

    /* clear the visible GPRs so the incoming-task reload is stark */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %edi, %edi

    movl    $0x11111111, 0x00002000     /* "task1 reached the switch point" */
    movl    $0x1A1A1A1A, %eax           /* live EAX the outgoing save records */

    /* ===================== THE NESTING TASK SWITCH ======================== *
     * Far CALL to the TSS2 selector (0x28), offset ignored. IA-32 (and QEMU):
     *   - saves task1 state into TSS1 (TR), incl. EIP = the instruction AFTER
     *     the lcall (task1_resumed) and the live EAX = 0x1A1A1A1A,
     *   - writes the OUTGOING TR selector (0x20) into TSS2's back-link (0x4000),
     *   - leaves TSS1's descriptor BUSY (0x8B -- the caller stays an active
     *     task), sets TSS2 busy, TR <- 0x28,
     *   - loads task2 state from TSS2 with EFLAGS.NT SET,
     *   - resumes at task2.
     * The C-04 defect ran the JMP form instead: no back-link write, no NT,
     * TSS1 busy CLEARED. */
    lcall   $0x28, $0                   /* NESTING TASK SWITCH to TSS2 */

    /* ===================== task1 resumes here ============================= *
     * Reached ONLY by task2's NT-IRET task-switching back through the TSS2
     * back-link the CALL wrote. If the JMP form ran (the defect), the
     * back-link is 0 and NT is clear: task2's IRET is an ordinary return into
     * garbage and this label is never reached -- the differential diverges. */
    .global task1_resumed
task1_resumed:
    movl    $0x99999999, 0x00002010     /* "returned to task1 via NT-IRET" */
    pushfl
    popl    %eax
    movl    %eax, 0x00002014            /* task1 EFLAGS after return: NT CLEAR */
    movzbl  0x00000525, %eax            /* TSS1 access byte (expect 0x8B busy) */
    movzbl  0x0000052D, %ebx            /* TSS2 access byte (expect 0x89 avail) */
    shll    $8, %eax
    orl     %ebx, %eax                  /* 0x8B89: incoming busy, IRET cleared outgoing */
    movl    %eax, 0x00002018

    /* pull the witnesses into the GPRs for the exit record (the differential
     * compares the final retired register state):
     *   edi = back-link (0x20)        ebp = task2 EFLAGS with NT set
     *   edx = TSS1 saved EIP          esi = TSS1 saved EAX (0x1A1A1A1A)
     *   ecx = (TSS1acc<<8)|TSS2acc at the CALL (0x8B8B)                      */
    movl    0x00002030, %edi
    movl    0x00002034, %ebp
    movl    0x00002038, %ecx
    movl    0x00002040, %edx
    movl    0x00002044, %esi

    /* isa-debug-exit: out 0xf4, 0x42 -> qemu status (0x42<<1)|1 = 133. */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
hang1:
    hlt
    jmp     hang1

    /* ============================== task2 =============================== *
     * The INCOMING (nested) task. Entered with the state loaded from TSS2
     * (EAX=0xAAAAAAAA, EBX=0xBBBBBBBB, ESP=0x00070000, segs flat) PLUS the
     * CALL-only semantics the finding is about: NT set in EFLAGS and the
     * back-link field at TSS2+0 holding 0x20. Records the witnesses, then
     * returns to the caller with an NT-IRET.                                   */
    .align 16
    .global task2
task2:
    /* reload proof (same as ptask) */
    movl    %eax, 0x00002020            /* 0xAAAAAAAA */
    movl    %ebx, 0x00002024            /* 0xBBBBBBBB */
    movl    %esp, 0x00002028            /* 0x00070000 */
    movl    $0x22222222, 0x0000202C     /* "task2 is running" */

    /* WITNESS 1 -- the back-link: TSS2+0 must now hold 0x0020, the OUTGOING
     * TR selector. Written by the CALL; the JMP form writes nothing here.   */
    movzwl  0x00004000, %eax
    movl    %eax, 0x00002030            /* expect 0x00000020 */

    /* WITNESS 2 -- NT in the incoming EFLAGS image (bit 14). */
    pushfl
    popl    %eax
    movl    %eax, 0x00002034            /* expect bit14 set (0x00004xxx) */

    /* WITNESS 3 -- BOTH descriptors busy. GDT base 0x500: TSS1 access @
     * 0x500+0x20+5 = 0x525, TSS2 access @ 0x500+0x28+5 = 0x52D. A CALL keeps
     * the OUTGOING TSS busy (the JMP form clears it -> 0x898B).             */
    movzbl  0x00000525, %eax            /* TSS1 access (expect 0x8B BUSY) */
    movzbl  0x0000052D, %ebx            /* TSS2 access (expect 0x8B busy) */
    shll    $8, %eax
    orl     %ebx, %eax
    movl    %eax, 0x00002038            /* expect 0x00008B8B */

    /* WITNESS 4 -- the outgoing save's resume EIP == the instruction after
     * the lcall. */
    movl    0x00003020, %eax            /* TSS1 saved EIP */
    movl    %eax, 0x00002040
    xorl    %ebx, %ebx
    cmpl    $task1_resumed, %eax
    sete    %bl
    movl    %ebx, 0x0000203C            /* expect 1 */

    /* WITNESS 5 -- the outgoing save captured the live EAX at the lcall. */
    movl    0x00003028, %eax            /* TSS1 saved EAX */
    movl    %eax, 0x00002044            /* expect 0x1A1A1A1A */

    movl    $0x33333333, 0x00002048     /* "task2 about to NT-IRET back" */

    /* ===================== THE NESTED-TASK RETURN ========================= *
     * IRET with EFLAGS.NT=1 (set by the CALL): a TASK RETURN through TSS2's
     * back-link (0x20), NOT a frame pop. Clears TSS2's busy bit, keeps TSS1
     * busy, restores task1's saved context, resumes at task1_resumed.
     * NT is already set in task2's EFLAGS image -- no manual OR needed: the
     * CALL put it there, which is half of what this test proves.            */
    iret

    /* Unreachable: the NT-IRET task-switches away. */
    movl    $0xDEADDEAD, 0x0000204C
hang2:
    hlt
    jmp     hang2

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off                /* 16-bit offset within segment 0xF000 */
    .word   0xF000                      /* segment */
