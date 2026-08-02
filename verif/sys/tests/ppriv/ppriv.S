/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* ppriv — REVIEW_aug2 H-06: privileged instructions that CPL3 could still execute.
 *
 * ############################################################################
 * # STATUS: the GOLDEN is graded; the RTL DIFF IS NOT RUN. Read this first.  #
 * #                                                                          #
 * # This image is in verify-sys, and steps 1-6 fully validate the golden --   #
 * # qemu 8.2.2 raises #GP(0) at CPL3 for all three instructions. Step 7 (the  #
 * # RTL --system diff) is explicitly SKIPPED, because the RTL cannot execute  #
 * # the instructions under test in this TB build:                            #
 * #                                                                          #
 * #   * the decoder only recognises RDTSC/INVD/WBINVD when cosim_en or soc_en #
 * #     is set; with both off they are out-of-scope opcodes that HALT before  #
 * #     the privilege predicate is consulted, AND                            #
 * #   * tb_main.cpp's --soc-en is a NO-OP here: the assignment sits inside    #
 * #     #ifdef VEN_KV260_SOC, and ventium_top ties the core's soc_en to 1'b0  #
 * #     in the non-KV260 generate branch. Measured, not assumed: passing      #
 * #     --soc-en left the core taking #UD on the CPL0 WBINVD.                 #
 * #                                                                          #
 * # So the H-06 RTL fix is LIVE only where soc_en=1 -- the deployed config,   #
 * # which is where it matters -- and is UNGATED. Do not read this test's      #
 * # green line as covering the RTL. Re-enable it in RTL_SYS_TESTS once        #
 * # --soc-en reaches the core in the default build.                          #
 * ############################################################################
 *
 * WHAT WAS WRONG
 * --------------
 * The centralized CPL0 predicate in core.sv omitted three instructions:
 *
 *   INVD  (0F 08) and WBINVD (0F 09) decode to ANONYMOUS NOPs. Retiring them as
 *      NOPs is right for their architectural effect -- Ventium's caches stay
 *      coherent with the flat memory model -- but an anonymous NOP gives the
 *      privilege check nothing to reject, so CPL3 code executed them freely.
 *      (INVD at CPL3 on real hardware discards modified cache lines.)
 *
 *   RDTSC (0F 31) is readable at any CPL *unless* CR4.TSD is set; that bit exists
 *      precisely so a supervisor can deny user code a high-resolution timer. The
 *      decoder said the check was "not modeled (firmware runs CPL0 with TSD=0)",
 *      which is true of firmware and says nothing about the CPL3 software TSD is
 *      there to restrict.
 *
 * WHAT THIS TEST GRADES
 * ---------------------
 * At CPL0 (controls -- these must still work):
 *      WBINVD, INVD          -> retire as NOPs
 * At CPL3, with CR4.TSD set by the CPL0 code beforehand:
 *      case A  WBINVD        -> #GP(0)
 *      case B  INVD          -> #GP(0)
 *      case C  RDTSC         -> #GP(0)   (because CR4.TSD=1 and CPL=3)
 *
 * Each fault is a CROSS-privilege delivery to the CPL0 handler on the TSS stack;
 * the handler records the frame, counts, patches the return EIP past the faulting
 * instruction and IRETs back to CPL3.
 *
 * All three faults carry error code 0, and none of them writes a register, so every
 * graded record is deterministic -- so this WILL be gradable differentially against
 * the golden as soon as the RTL can execute the instructions (STATUS banner above).
 *
 * KNOWN GAP, stated rather than implied: the PERMISSIVE direction of the TSD rule
 * -- "RDTSC at CPL3 with CR4.TSD=0 must NOT fault" -- is deliberately absent. A
 * successful RDTSC writes EDX:EAX from a free-running counter, so its value can
 * never match between QEMU and the RTL, and verif/diff/compare.py has no
 * per-field ignore. Putting it in this image would make the gate unpassable for a
 * reason that has nothing to do with H-06. What IS covered here is the direction
 * that was a privilege hole; the permissive direction rests on `rdtsc_priv`
 * requiring creg4[2], which is one term in one expression.
 *
 * (See the STATUS banner above for why the RTL half of this is not gated yet.)
 *
 * Layout follows pcpl:
 *   GDT @ 0x0500 (6 entries)   IDT @ 0x1000   markers @ 0x2000   TSS @ 0x3000
 *   CPL0 boot stack 0x00090000, TSS.ESP0 0x00088000, CPL3 stack 0x00080000
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

    /* GDT: null, code0 0x08, data0 0x10, code3 0x18, data3 0x20, TSS32 0x28 */
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

    movw    $0x002F, 0x0480
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

    /* TSS @ 0x3000 */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00088000, 0x00003004
    movl    $0x00000010, 0x00003008
    movw    $0x0068, 0x00003066
    movw    $0x0028, %ax
    ltr     %ax

    /* IDT: vector 13 (#GP) -> gp_handler (DPL0); vector 0x40 -> sys_exit (DPL3) */
    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 4(%edi)

    movl    $sys_exit, %ebx
    movl    $0x00001200, %edi
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x0000EE00, %eax
    movl    %eax, 4(%edi)

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- CPL0 CONTROLS: these must execute, not fault -------------------- */
    /* If the H-06 predicate were written as "reject INVD/WBINVD unconditionally"
     * rather than "reject them at CPL != 0", these two would #GP here and the test
     * would fail before it ever reached CPL3. That is the point of running them. */
    wbinvd
    invd
    movl    $0x00C0FFEE, 0x00002040     /* "CPL0 controls survived" */

    /* ---- arm CR4.TSD so RDTSC becomes CPL0-only -------------------------- */
    movl    %cr4, %eax
    orl     $0x00000004, %eax           /* CR4.TSD (bit 2) */
    movl    %eax, %cr4

    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %ebp, %ebp

    /* ---- transfer DOWN to CPL3 ------------------------------------------- */
    pushl   $0x00000023                 /* SS  = data3 RPL3 */
    pushl   $0x00080000                 /* ESP = CPL3 stack */
    pushfl
    orl     $0x00000200, (%esp)
    pushl   $0x0000001B                 /* CS  = code3 RPL3 */
    pushl   $user_entry
    iret

hang0:
    jmp     hang0

    /* ============================ CPL3 USER TASK ========================= */
    .align 16
    .global user_entry
user_entry:
    movw    $0x0023, %ax
    movw    %ax, %ds
    movw    %ax, %es

    /* case A: WBINVD at CPL3 -> #GP(0). The handler resumes at caseB. */
    movl    $caseB, 0x00002044
    wbinvd

    .align 16
caseB:                                  /* case B: INVD at CPL3 -> #GP(0) */
    movl    $caseC, 0x00002044
    invd

    .align 16
caseC:                                  /* case C: RDTSC at CPL3, CR4.TSD=1 -> #GP(0).
                                         * The fault means EDX:EAX are NOT written, so
                                         * nothing counter-valued enters the trace. */
    movl    $caseD, 0x00002044
    rdtsc

    .align 16
caseD:
    movl    $0xC3C3C3C3, 0x00002048     /* all three faults survived, still at CPL3 */
    xorl    %eax, %eax
    movw    %ss, %ax
    movl    %eax, 0x0000204C            /* user SS (expect 0x0023) */
    int     $0x40                       /* trap to CPL0 to report + exit */
uhang:
    jmp     uhang

    /* ============================== HANDLER ==============================
     * #GP from CPL3 is a CROSS-privilege delivery: the CPU switches to
     * TSS.SS0:ESP0 and pushes SS, ESP, EFLAGS, CS, EIP and the error code, so on
     * entry the stack is
     *   [esp+ 0] error code   [esp+ 4] EIP   [esp+ 8] CS
     *   [esp+12] EFLAGS       [esp+16] ESP   [esp+20] SS
     * The handler records the frame, counts, patches the saved EIP to the next
     * case (each faulting instruction is the last thing in its case) and IRETs
     * back to CPL3.                                                            */
    .align 16
    .global gp_handler
gp_handler:
    pushl   %eax
    pushl   %ebx
    /* frame fields shifted +8 by the two pushes */
    movl    0x08(%esp), %eax            /* error code -- must be 0 */
    movl    %eax, 0x00002050
    movl    0x10(%esp), %eax            /* saved CS -- must be 0x1B (faulted AT CPL3) */
    movl    %eax, 0x00002054
    movl    0x18(%esp), %eax            /* saved SS -- must be 0x23 */
    movl    %eax, 0x00002058

    incl    0x0000205C                  /* total faults */
    movl    0x00002050, %eax
    testl   %eax, %eax                  /* error code 0? */
    jnz     1f
    incl    0x00002060                  /* faults with error code 0 */
1:
    movl    0x00002054, %eax
    cmpl    $0x0000001B, %eax           /* raised while genuinely at CPL3? */
    jne     2f
    incl    0x00002064
2:
    movl    0x00002044, %eax            /* staged resume target */
    movl    %eax, 0x0C(%esp)            /* overwrite the saved EIP */
    popl    %ebx
    popl    %eax
    addl    $4, %esp                    /* discard the error code */
    iret                                /* inter-priv IRET back to CPL3 */

    /* sys_exit — CPL0, reached cross-priv via INT 0x40. Reports and exits. */
    .align 16
    .global sys_exit
sys_exit:
    movl    0x0000205C, %ebp            /* EBP = faults taken           (want 3) */
    movl    0x00002060, %ebx            /* EBX = error code 0 each time (want 3) */
    movl    0x00002064, %ecx            /* ECX = all raised at CPL3     (want 3) */
    movl    0x00002048, %edx            /* EDX = 0xC3C3C3C3 (CPL3 survived all 3) */
    movl    0x0000204C, %esi            /* ESI = user SS                (want 0x23) */
    movl    0x00002040, %edi            /* EDI = 0x00C0FFEE (CPL0 controls ran) */

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
