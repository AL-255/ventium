/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW1_Aug3 R2-C01 — S_LJMP per-kind privilege/type validation for far
 * transfers (direct JMP/CALL, RETF, call-gate targets, TSS transfers).
 *
 * The defect (rtl/core/core_seg_ljmp.svh, pre-fix): the shared S_LJMP state
 * handled direct JMP, direct CALL, same-level RETF, call-gate targets and TSS
 * transfers with a collection of booleans and NO per-kind validator:
 *   1. a direct far JMP/CALL to NONCONFORMING code never enforced DPL == CPL
 *      and RPL <= CPL (a crafted selector could LOWER cpl_r);
 *   2. a RETF whose popped CS had RPL < CPL took the same-level path and
 *      lowered CPL (may never RAISE privilege);
 *   3. a RETF whose popped selector named a SYSTEM descriptor (TSS/gate/LDT)
 *      entered the TSS/gate resolver instead of #GP(selector);
 *   4. a direct JMP/CALL to a TSS lacked the TI==0 and DPL >= max(CPL,RPL)
 *      checks (a ring-3 caller could target a ring-0 TSS, and a TSS-like
 *      descriptor in the LDT was accepted);
 *   5. a NOT-PRESENT TSS or call gate fell through to the unsupported-
 *      descriptor HALT instead of #NP(selector);
 *   6. a call-gate target with nonconforming DPL > CPL was accepted as a
 *      same-privilege transfer.
 * The fix (landed, uncommitted) adds exactly these validators. Every rejected
 * transfer must perform NO stack write, NO TSS/busy-bit write and NO
 * architectural-state change -- witnessed here by the ESP at the fault and by
 * the GDT/LDT busy bytes read back afterwards.
 *
 * TWENTY REJECTED transfers + THREE ACCEPTED controls in one image, all graded
 * DIFFERENTIALLY against the QEMU 8.2.2 golden (QEMU implements every one of
 * these rules -- verified in the pinned harness source
 * target/i386/tcg/seg_helper.c: helper_ljmp_protected / helper_lcall_protected
 * / helper_ret_protected / switch_tss_ra), with ONE documented oracle gap:
 *
 *   case 4 (direct JMP to an LDT-resident TSS, selector 0x0004): QEMU raises
 *   #TS(0x0004) (switch_tss_ra's `tss_selector & 4` check fires #TS for BOTH
 *   direct jumps and IRET returns). SDM Vol.3A 8.2.2 "TSS Descriptor" is
 *   explicit: an access to a TSS through a selector with TI set "causes a
 *   general-protection exception (#GP) ... during CALLs and JMPs; it causes an
 *   invalid TSS exception (#TS) during IRETs". The RTL follows the SDM
 *   (#GP(0x0004), TI preserved). The flows are made IDENTICAL for the
 *   differential by routing IDT vectors 10 AND 13 to the SAME handler entry
 *   (the pssiret precedent): the error code is 0x0004 in both oracles and the
 *   ESP-at-fault is identical, so the trace flows match record-for-record;
 *   the VECTOR NUMBER, which the trace then cannot see, is graded DIRECTLY
 *   from the RTL +ven_faultlog in run-sys-golden.sh (vec=13 err=00000004,
 *   exactly once, and no vec=10 at all) -- exactly the pssiret pattern, so
 *   the sharing cannot hide a wrong vector.
 *
 * THE CASES
 *   CPL0 phase (task1):
 *    1. lcall 0x000B (code0 nonconf DPL0 with RPL 3)  -> #GP(0x08)  [fix 1: RPL>CPL]
 *    2. ljmp  0x30   (CONFORMING code DPL1)           -> #GP(0x30)  [fix 1: conf DPL>CPL]
 *    3. RETF popped CS = 0x38 (TSS_A descriptor)      -> #GP(0x38)  [fix 3: system desc]
 *    4. ljmp  0x0004 (TSS in LDT entry 0)             -> #GP(0x0004) [fix 4: TI must be 0]
 *       (QEMU: #TS(0x0004) -- the oracle gap above; shared handler)
 *    5. ljmp  0x48   (TSS_NP, P=0)                    -> #NP(0x48)  [fix 5: not-present TSS]
 *    6. lcall 0x50   (call gate, P=0)                 -> #NP(0x50)  [fix 5: not-present gate]
 *    7. lcall 0x58   (gate -> 0x60 nonconf DPL1)      -> #GP(0x60)  [fix 6: target DPL>CPL]
 *    8. ljmp  0x68   (CONFORMING DPL0)                -> ACCEPTED (control: direct JMP conf)
 *    9. lcall 0x08 -> callee9 -> lret                 -> ACCEPTED (control: RETF same-level)
 *   10. ljmp  0x70   (TSS2, available, DPL0)          -> ACCEPTED task switch (control:
 *       JMP to a valid available TSS) -> task2
 *   CPL3 phase (task2 transferred down via an outer RETF):
 *   11. ljmp  0x08   (code0 nonconf DPL0, from CPL3)  -> #GP(0x08)  [fix 1: DPL!=CPL]
 *   12. lcall 0x80   (TSS_C available DPL0, from CPL3)-> #GP(0x80)  [fix 4: DPL<CPL]
 *   13. RETF popped CS = 0x0008 (RPL 0 < CPL 3)       -> #GP(0x08)  [fix 2: RETF may not
 *       raise privilege]
 *
 * COMBINED-INVALID MATRIX (system-descriptor dispatch precedence): the
 * typed classifier runs TYPE/DPL classification BEFORE PRESENCE, exactly the
 * pinned oracle's order (helper_ljmp/helper_lcall's system-branch
 * switch(type) + DPL arms, then switch_tss_ra's presence checks). Each
 * combined case pairs with a single-invalid control; all are differential
 * (QEMU raises the same vector + error code for every one):
 *   CPL0 phase (before the case-10 switch):
 *   14. ljmp  0x98   (busy 386 TSS, P=0)                -> #GP(0x98)  [combined: busy AND
 *       absent; the oracle's default case, never a presence check. NOT #NP]
 *   15. ljmp  0x90   (busy 386 TSS, P=1)                -> #GP(0x90)  [control: present busy]
 *   16. ljmp  0xA0   (LDT descriptor, P=0)              -> #GP(0xA0)  [combined: wrong class
 *       AND absent; #GP present or not. NOT #NP]
 *   17. ljmp  0x40   (LDT descriptor, P=1)              -> #GP(0x40)  [control: present LDT]
 *   18. ljmp  0xA8   (task gate, P=0, admissible DPL)   -> #NP(0xA8)  [control: presence-only,
 *       switch_tss_ra's gate P check]
 *   19. ljmp  0x00AB (task gate, P=0, RPL 3 > DPL 0)    -> #GP(0xA8)  [combined: privilege
 *       before presence. NOT #NP]
 *   CPL3 phase:
 *   20. ljmp  0x48   (TSS_NP: avail TSS DPL0 P=0)       -> #GP(0x48)  [combined: DPL<CPL
 *       before presence (case 5 is the same selector #NP from CPL0). NOT #NP]
 *   21. ljmp  0x88   (avail TSS DPL3 P=0, from CPL3)    -> #NP(0x88)  [control: presence-only]
 *   22. ljmp  0xB0   (task gate, P=1, DPL0, from CPL3)  -> #GP(0xB0)  [gate DPL<CPL in the
 *       helper, before switch_tss_ra]
 *   23. lcall 0x50   (call gate, P=0, DPL0, from CPL3)  -> #GP(0x50)  [combined: gate DPL<CPL
 *       before presence (case 6 is the same gate #NP from CPL0). NOT #NP]
 * The call-gate family's presence-only control is case 6 (deduped). The one
 * form NOT in this image: task gate P=1 with admissible DPL -- the oracle
 * ACCEPTS it (switches through the gate to TSS2) but this core loud-HALTs
 * after the faults, so the shape is not differentially expressible (an
 * accept-gap, documented in manifest.json).
 *   then exit from CPL3 (IOPL=3 in the TSS2 EFLAGS image).
 *
 * Memory plan (NO paging -- the R2-C01 validation rules are paging-independent;
 * the paged selector/nullness defects are pselnull's):
 *   GDT  @ 0x00000500   23 entries (limit 0xB7), see the build table below
 *   IDT  @ 0x00001000   gates 10+13 -> gp_entry (SHARED), 11 -> np_entry (0x8E)
 *   markers @ 0x00002000, faultlog slots @ 0x00002800 (12 B/case: vec,err,esp)
 *   staging @ 0x00002FDC: busy_ok/ngp/nnp/esp_ok/c4_ok/cur_slot/resume/pre_esp/
 *   cases_ok
 *   LDT  @ 0x00003400   entry 0 = an available TSS descriptor (case 4)
 *   TSS1 @ 0x00004000 (task1, LTR'd; SS0=0x10 ESP0=0x6000)
 *   TSS_A @ 0x00004100, TSS_NP @ 0x00004200, LDT-TSS @ 0x00004300 (content
 *   unused -- all three are REJECTED, so only their descriptors matter)
 *   TSS2 @ 0x00004400 (incoming image = task2; SS0=0x10 ESP0=0x6800)
 *   TSS_C @ 0x00004600, TSS_D3NP @ 0x00004700, TSS_B @ 0x00004800, TSS_BNP @
 *   0x00004900 (descriptor only -- all rejected, content never touched)
 *   stacks: task1 0x7000, ring3 0x5000, TSS2-SS0 0x6800, task2 0x8000
 *
 * WITNESSES (pulled into the GPRs before the isa-debug-exit so the
 * golden-vs-RTL differential compares them; step-5g asserts them):
 *   edi = (nnp<<16)|ngp == 0x0004000F  -- four #NP (cases 5,6,18,21) +
 *         fifteen #GP (cases 1,2,3,7,11,12,13,14,15,16,17,19,20,22,23),
 *         vectors recorded by the handlers
 *   esi = (c4_ok<<16)|(busy_ok<<8)|esp_ok == 0x00010914 -- case 4 faulted
 *         with err 0x0004 (TI preserved) AND all 9 descriptor access bytes
 *         the rejected transfers named read back EXACTLY as built (no
 *         busy-bit/type/presence rewrite) AND every one of the 20 rejected
 *         transfers left ESP EXACTLY as it was at the faulting instruction
 *         (no stack write, no ESP move: the far-CALL probe faults before
 *         the push, the RETF ESP advance is staged, the TSS rejects
 *         precede S_TSW_*)
 *   ebp = (TSS_A.acc<<8)|TSS_C.acc == 0x00008989 -- the busy bytes of the two
 *         AVAILABLE TSS descriptors the rejected transfers named (cases 3,12)
 *         are UNTOUCHED: no task switch, no busy-bit write
 *   ebx = (TSS1.acc<<8)|TSS2.acc == 0x0000898B -- the ACCEPTED switch (case 10)
 *         toggled the busy bits (outgoing cleared 0x8B->0x89, incoming set
 *         0x89->0x8B): the JMP-to-valid-TSS control really happened
 *   ecx = (case1.err<<16)|case12.err == 0x00080080 -- the handler-recorded
 *         error codes name the rejected selectors
 *
 * NEGATIVE CONTROL (REQUIRED, see manifest.json): the HEAD TB (no R2-C01 fix)
 * accepts case 1 (lcall RPL3>CPL0 pushes a frame and runs offset 0), so the
 * traces diverge at the first lcall already; independently: case 2 jumps into
 * the conforming DPL1 segment, case 3 task-switches into TSS_A, case 4 task-
 * switches into the LDT TSS, cases 5/6 hit the unsupported-descriptor HALT,
 * case 7 runs the DPL1 target, case 11 lowers CPL to 0, case 12 nesting-
 * switches into TSS_C, case 13 lowers CPL to 0. Every case diverges.
 * For the combined-invalid matrix the precedence defect is reproduced
 * directly: a scratch RTL with the presence arm moved back AHEAD of the
 * type/DPL arms reports #NP where the oracle requires #GP for every combined
 * case (14, 16, 19, 20, 23 -- the single-invalid controls are invisible to
 * the reorder by construction), and the differential diverges at the first
 * of them (see manifest.json's negative_control for the measured run).
 *
 * GNU-as syntax; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
 */

/* ---- staging area (0x2FDC..0x2FFF) ------------------------------------ */
.set CNT_BUSYOK, 0x00002FDC      /* descriptor-access-byte-clean counter     */
.set CNT_NGP,    0x00002FE0      /* #GP(13) counter                          */
.set CNT_NNP,    0x00002FE4      /* #NP(11) counter                          */
.set CNT_ESPOK,  0x00002FE8      /* ESP-preserved counter (all 20 rejects)   */
.set CNT_C4OK,   0x00002FEC      /* case 4: err==0x0004, vec in {10,13}      */
.set CUR_SLOT,   0x00002FF0      /* current faultlog slot pointer            */
.set RESUME_ADR, 0x00002FF4      /* staged handler resume address            */
.set PRE_ESP,    0x00002FF8      /* ESP captured before the faulting insn    */
.set CNT_OK,     0x00002FFC      /* fully-matched cases counter              */
.set SLOTS,      0x00002800      /* 12-byte slots: +0 vec, +4 err, +8 esp    */

/* STAGE slot, resume: point the handler at a slot + resume address and
 * capture ESP right before the faulting instruction. */
.macro STAGE slot, resume
    movl    $(\slot), CUR_SLOT
    movl    $(\resume), RESUME_ADR
    movl    %esp, PRE_ESP
.endm

/* CHECK vec, err, discard: verify the slot the handler filled: the recorded
 * vector and error code match, the handler-recorded ESP-at-fault equals the
 * pre-instruction ESP, and the CURRENT esp is equally untouched; then discard
 * any fake stack frame. On a full match bump cases_ok (+ the per-vector and
 * esp counters). */
.macro CHECK vec, err, discard
    movl    CUR_SLOT, %ebx
    movl    (%ebx), %eax
    cmpl    $(\vec), %eax
    jne     991f
    movl    4(%ebx), %eax
    cmpl    $(\err), %eax
    jne     991f
    movl    8(%ebx), %eax
    cmpl    PRE_ESP, %eax
    jne     991f
    cmpl    PRE_ESP, %esp
    jne     991f
    incl    CNT_OK
    .if \vec == 13
    incl    CNT_NGP
    .endif
    .if \vec == 11
    incl    CNT_NNP
    .endif
    incl    CNT_ESPOK
991:
    .if \discard
    addl    $(\discard), %esp
    .endif
.endm

/* ACCCHK addr, expect: a REJECTED transfer must leave the named descriptor's
 * access byte EXACTLY as built (no busy-bit set, no type/presence rewrite).
 * Bump the clean counter only on a match. */
.macro ACCCHK addr, expect
    movzbl  (\addr), %eax
    cmpb    $(\expect), %al
    jne     994f
    incl    CNT_BUSYOK
994:
.endm

    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ss
    movw    %ax, %ds
    movw    $0x7000, %sp

    /* GDT at 0x0500 (23 entries, limit 0xB7):
     *   0x08 code0 nonconf DPL0 flat (0x9A)   0x10 data0 DPL0 flat (0x92)
     *   0x18 code3 nonconf DPL3 flat (0xFA)   0x20 data3 DPL3 flat (0xF2)
     *   0x28 TSS1  available base 0x4000      0x30 code CONFORMING DPL1 base 0xF0000
     *   0x38 TSS_A available base 0x4100      0x40 LDT desc: LDT @ 0x3400 limit 0x07
     *   0x48 TSS_NP NOT-PRESENT base 0x4200   0x50 call gate P=0 -> 0x08
     *   0x58 call gate DPL0 -> 0x60           0x60 code NONCONFORMING DPL1 base 0xF0000
     *   0x68 code CONFORMING DPL0 base 0xF0000
     *   0x70 TSS2  available base 0x4400      0x78 filler data
     *   0x80 TSS_C available base 0x4600
     *   0x88 TSS_D3NP available DPL3 P=0      0x90 TSS_B busy P=1 base 0x4800
     *   0x98 TSS_BNP busy P=0 base 0x4900     0xA0 LDT desc P=0 (base 0x3500 limit 0x07)
     *   0xA8 task gate P=0 -> TSS2            0xB0 task gate P=1 -> TSS2       */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508        /* 0x08 code0 */
    movl    $0x00cf9a00, 0x050c
    movl    $0x0000ffff, 0x0510        /* 0x10 data0 */
    movl    $0x00cf9200, 0x0514
    movl    $0x0000ffff, 0x0518        /* 0x18 code3 */
    movl    $0x00cffa00, 0x051c
    movl    $0x0000ffff, 0x0520        /* 0x20 data3 */
    movl    $0x00cff200, 0x0524
    /* 0x28 TSS1: base 0x4000, limit 0x67, access 0x89 */
    movl    $0x40000067, 0x0528
    movl    $0x00008900, 0x052c
    /* 0x30 code CONFORMING DPL1, base 0xF0000, limit 0xFFFF (acc 0xBE) */
    movl    $0x0000ffff, 0x0530
    movl    $0x0040be0f, 0x0534
    /* 0x38 TSS_A: base 0x4100 */
    movl    $0x41000067, 0x0538
    movl    $0x00008900, 0x053c
    /* 0x40 LDT descriptor: base 0x3400, limit 0x07, access 0x82 */
    movl    $0x34000007, 0x0540
    movl    $0x00008200, 0x0544
    /* 0x48 TSS_NP: base 0x4200, access 0x09 (P=0, 32-bit TSS) */
    movl    $0x42000067, 0x0548
    movl    $0x00000900, 0x054c
    /* 0x50 call gate P=0 -> sel 0x08, offset 0, access 0x0C */
    movl    $0x00080000, 0x0550
    movl    $0x00000c00, 0x0554
    /* 0x58 call gate DPL0 P -> sel 0x60, offset 0, access 0x8C */
    movl    $0x00600000, 0x0558
    movl    $0x00008c00, 0x055c
    /* 0x60 code NONCONFORMING DPL1, base 0xF0000 (acc 0xBA) */
    movl    $0x0000ffff, 0x0560
    movl    $0x0040ba0f, 0x0564
    /* 0x68 code CONFORMING DPL0, base 0xF0000 (acc 0x9E) */
    movl    $0x0000ffff, 0x0568
    movl    $0x00409e0f, 0x056c
    /* 0x70 TSS2: base 0x4400 */
    movl    $0x44000067, 0x0570
    movl    $0x00008900, 0x0574
    /* 0x78 filler data */
    movl    $0x0000ffff, 0x0578
    movl    $0x00cf9200, 0x057c
    /* 0x80 TSS_C: base 0x4600 */
    movl    $0x46000067, 0x0580
    movl    $0x00008900, 0x0584
    /* 0x88 TSS_D3NP: available 386 TSS, DPL3, P=0, base 0x4700 (acc 0x69) --
     * the presence-only control: reachable from CPL3, absent -> #NP. */
    movl    $0x47000067, 0x0588
    movl    $0x00006900, 0x058c
    /* 0x90 TSS_B: busy 386 TSS, P=1, base 0x4800 (acc 0x8B) -- busy control. */
    movl    $0x48000067, 0x0590
    movl    $0x00008b00, 0x0594
    /* 0x98 TSS_BNP: busy 386 TSS, P=0, base 0x4900 (acc 0x0B) -- combined
     * invalid (busy AND absent): the type rule wins -> #GP, never #NP. */
    movl    $0x49000067, 0x0598
    movl    $0x00000b00, 0x059c
    /* 0xA0 LDT_NP: an LDT descriptor with P=0 (acc 0x02) -- combined invalid
     * (wrong class AND absent): the class rule wins -> #GP, never #NP. */
    movl    $0x35000007, 0x05a0
    movl    $0x00000200, 0x05a4
    /* 0xA8 task gate, P=0, DPL0 -> TSS2 (0x70), acc 0x05 -- absent gate:
     * #NP when the caller's privilege is admissible, #GP when it is not. */
    movl    $0x00700000, 0x05a8
    movl    $0x00000500, 0x05ac
    /* 0xB0 task gate, P=1, DPL0 -> TSS2 (0x70), acc 0x85 -- a present gate
     * targeted from CPL3 faults #GP on the gate DPL BEFORE the switch. */
    movl    $0x00700000, 0x05b0
    movl    $0x00008500, 0x05b4

    movw    $0x00B7, 0x0480            /* GDT limit = 23*8-1 */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                 /* opsize-32 ljmp ptr16:32 */
    .long   pm_entry
    .word   0x08

    .code32
    .section .text32,"ax"
    .global pm_entry
pm_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00007000, %esp

    /* ---- zero markers 0x2000..0x2020, slots 0x2800..0x28F0, staging ------- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $8, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00002800, %edi
    movl    $60, %ecx                 /* 20 slots x 12 B */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00002FDC, %edi
    movl    $9, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000: vectors 10 AND 13 -> gp_entry (SHARED, the pssiret
     * precedent -- see the header: QEMU raises #TS where the SDM says #GP for
     * case 4; the vector is graded from +ven_faultlog, the flows are made
     * identical here); vector 11 -> np_entry. All interrupt gates CPL0. ---- */
    movl    $0x00001000, %edi
    movl    $32, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $gp_entry, %ebx
    movl    $0x00001050, %edi           /* 0x1000 + 10*8 (#TS) */
    call    set_gate0
    movl    $np_entry, %ebx
    movl    $0x00001058, %edi           /* 0x1000 + 11*8 (#NP) */
    call    set_gate0
    movl    $gp_entry, %ebx
    movl    $0x00001068, %edi           /* 0x1000 + 13*8 (#GP) */
    call    set_gate0
    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- LDT @ 0x3400, entry 0: an AVAILABLE TSS (base 0x4300, limit 0x67,
     * access 0x89) -- the case-4 target. TSS descriptors may only live in the
     * GDT (SDM Vol.3A 8.2.2), so a direct JMP naming it must #GP(0x0004). ---- */
    movl    $0x43000067, 0x00003400
    movl    $0x00008900, 0x00003404

    /* ---- TSS1 @ 0x4000: SS0=0x10 ESP0=0x6000, empty I/O map -------------- */
    movl    $0x00004000, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $0x00006000, 0x00004004     /* ESP0 */
    movl    $0x00000010, 0x00004008     /* SS0  */
    movw    $0x0068,     0x00004066

    /* ---- TSS2 @ 0x4400: the case-10 ACCEPTED switch's incoming image ------
     * task2 runs at CPL0 on the flat segments, ESP 0x8000, EFLAGS IOPL=3
     * (0x3202) so the CPL3 phase may drive port 0xF4; SS0=0x10 ESP0=0x6800
     * serves the cross-privilege #GP deliveries of cases 11-13.            */
    movl    $0x00004400, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $0x00006800, 0x00004404     /* ESP0 */
    movl    $0x00000010, 0x00004408     /* SS0  */
    movl    $task2,      0x00004420     /* EIP  */
    movl    $0x00003202, 0x00004424     /* EFLAGS: IOPL 3 */
    movl    $0x00008000, 0x00004438     /* ESP  */
    movl    $0x00000010, 0x00004448     /* ES   */
    movl    $0x00000008, 0x0000444C     /* CS   */
    movl    $0x00000010, 0x00004450     /* SS   */
    movl    $0x00000010, 0x00004454     /* DS   */
    movl    $0x00000010, 0x00004458     /* FS   */
    movl    $0x00000010, 0x0000445C     /* GS   */
    movw    $0x0068,     0x00004466     /* I/O map base (empty) */

    movw    $0x0028, %ax
    ltr     %ax

    /* ======================= case 1: CALL, RPL > CPL ====================== *
     * lcall to code0 (nonconforming DPL0) with the selector RPL cranked to 3.
     * RPL(3) > CPL(0) -> #GP(0x08). HEAD accepts it: the probe passes (DPL0 ==
     * CPL0) and a return frame is pushed for a run at offset 0 -- the traces
     * diverge here, at the FIRST rejected transfer.                        */
    STAGE   (SLOTS+0*12), c1_done
    .byte   0x9A                        /* lcall ptr16:32 */
    .long   0
    .word   0x000B                      /* 0x08 | RPL 3 */
c1_done:
    CHECK   13, 0x08, 0

    /* ================== case 2: JMP, conforming DPL > CPL ================= *
     * ljmp to the CONFORMING DPL1 segment from CPL0: DPL(1) > CPL(0) ->
     * #GP(0x30). HEAD had no conforming-DPL rule at all and transferred.    */
    STAGE   (SLOTS+1*12), c2_done
    .byte   0xEA                        /* ljmp ptr16:32 */
    .long   0
    .word   0x0030
c2_done:
    CHECK   13, 0x30, 0

    /* ================== case 3: RETF to a SYSTEM descriptor =============== *
     * Pop a fake frame whose CS names TSS_A (0x38, an available TSS). A RETF
     * may not resolve a system descriptor at all: #GP(0x38). HEAD fell into
     * the TSS resolver and TASK-SWITCHED into TSS_A (writing the busy bit and
     * the outgoing state). TSS_A's access byte must stay 0x89 -- read back in
     * task2 (ebp witness). ESP must be preserved (the RETF ESP advance is
     * staged and never fires on a reject): compare, THEN drop the fake frame. */
    STAGE   (SLOTS+2*12), c3_done
    pushl   $0x00000038                 /* popped CS = the TSS_A selector */
    pushl   $0x11111111                 /* popped EIP (irrelevant) */
    movl    %esp, PRE_ESP               /* ESP at the faulting lret */
    lret
c3_done:
    CHECK   13, 0x38, 8

    /* ============ case 4: JMP to a TSS in the LDT (TI must be 0) ========== *
     * LLDT the case-4 LDT, then ljmp selector 0x0004 (TI=1, LDT entry 0 = an
     * available TSS). SDM: #GP(0x0004) -- TSS descriptors may only live in the
     * GDT. QEMU deviates with #TS(0x0004) (oracle gap, see the header), so
     * vectors 10+13 share gp_entry; the RTL vector is graded via +ven_faultlog
     * and only the (oracle-identical) error code + ESP are checked here.
     * HEAD accepted the LDT-resident TSS and switched into it (garbage TSS at
     * 0x4300 -- outgoing save into TSS1 + a later fault: divergent).        */
    movw    $0x0040, %ax
    lldt    %ax
    STAGE   (SLOTS+3*12), c4_done
    .byte   0xEA
    .long   0
    .word   0x0004                      /* TI=1, LDT entry 0 */
c4_done:
    /* err must be 0x0004 (TI PRESERVED -- the R2-C02 selector_error form, not
     * {sel[15:3],3'b000} = 0x0000), the vector 10 (QEMU) or 13 (SDM/RTL), and
     * ESP untouched. */
    movl    CUR_SLOT, %ebx
    movl    4(%ebx), %eax
    cmpl    $0x00000004, %eax
    jne     992f
    movl    (%ebx), %eax
    cmpl    $10, %eax
    je      993f
    cmpl    $13, %eax
    jne     992f
993:
    movl    8(%ebx), %eax
    cmpl    PRE_ESP, %eax
    jne     992f
    cmpl    PRE_ESP, %esp
    jne     992f
    incl    CNT_C4OK
    incl    CNT_ESPOK
    incl    CNT_OK
992:

    /* ================== case 5: JMP to a NOT-PRESENT TSS ================== *
     * ljmp 0x48 (TSS_NP, P=0): #NP(0x48), not the unsupported-descriptor
     * HALT (HEAD halts -- the trace simply stops there). QEMU: #NP from
     * switch_tss_ra's present check.                                        */
    STAGE   (SLOTS+4*12), c5_done
    .byte   0xEA
    .long   0
    .word   0x0048
c5_done:
    CHECK   11, 0x48, 0

    /* ================= case 6: CALL through a NOT-PRESENT gate ============ *
     * lcall 0x50 (call gate, P=0): #NP(0x50). HEAD halts (unsupported
     * descriptor). QEMU: #NP(gate selector) from helper_lcall_protected.    */
    STAGE   (SLOTS+5*12), c6_done
    .byte   0x9A
    .long   0
    .word   0x0050
c6_done:
    CHECK   11, 0x50, 0

    /* ========= case 7: call-gate target, nonconforming DPL > CPL ========== *
     * lcall through gate 0x58 (DPL 0) to 0x60 (nonconforming DPL1) from CPL0:
     * the gate is reachable but the target is LESS privileged than the caller
     * -> #GP(0x60) naming the TARGET selector (both oracles: the gate resolver
     * substitutes it before the fault). HEAD accepted it as a same-privilege
     * transfer. The probe faults BEFORE any push (ESP witness).             */
    STAGE   (SLOTS+6*12), c7_done
    .byte   0x9A
    .long   0
    .word   0x0058
c7_done:
    CHECK   13, 0x60, 0

    /* ======= combined-invalid matrix: type/DPL classification BEFORE =======
     * ======= presence (the system-descriptor dispatch precedence)    =======
     * A descriptor that is invalid on TWO grounds must report the fault the
     * TYPE/PRIVILEGE classifier selects, not the not-present fault: the
     * oracle's helpers run their switch(type) + DPL arms FIRST and only reach
     * a presence check for a class they actually transfer through (verified
     * in the pinned source: helper_ljmp_protected / helper_lcall_protected's
     * system branch, then switch_tss_ra). Each combined case pairs with a
     * single-invalid control so the precedence is proven, not just the
     * vector. All differential: QEMU raises the same vectors/error codes.
     *
     * ============ case 14: JMP to a BUSY TSS that is also ABSENT ========== *
     * ljmp 0x98 (busy 386 TSS, P=0): a direct JMP/CALL never reaches a
     * presence check for the busy type -- the oracle's default case is
     * #GP(selector) outright. #GP(0x98), NOT #NP. Presence-first would #NP. */
    STAGE   (SLOTS+10*12), c14_done
    .byte   0xEA
    .long   0
    .word   0x0098
c14_done:
    CHECK   13, 0x98, 0

    /* ============== case 15 (control): JMP to a PRESENT busy TSS ========== *
     * ljmp 0x90 (busy 386 TSS, P=1): same default-case #GP(0x90) with the
     * presence bit set -- the busy reject is a TYPE rule, not presence.     */
    STAGE   (SLOTS+11*12), c15_done
    .byte   0xEA
    .long   0
    .word   0x0090
c15_done:
    CHECK   13, 0x90, 0

    /* ============ case 16: JMP to an LDT descriptor that is ABSENT ======== *
     * ljmp 0xA0 (LDT descriptor, P=0): an LDT descriptor is never a far-
     * transfer target -- the oracle's default case is #GP(selector) present
     * or not. #GP(0xA0), NOT #NP. Presence-first would #NP.                 */
    STAGE   (SLOTS+12*12), c16_done
    .byte   0xEA
    .long   0
    .word   0x00A0
c16_done:
    CHECK   13, 0xA0, 0

    /* ============ case 17 (control): JMP to a PRESENT LDT descriptor ====== *
     * ljmp 0x40 (the LLDT'd LDT descriptor, P=1): same default-case
     * #GP(0x40) -- the class reject does not consult presence.              */
    STAGE   (SLOTS+13*12), c17_done
    .byte   0xEA
    .long   0
    .word   0x0040
c17_done:
    CHECK   13, 0x40, 0

    /* ============ case 18 (control): JMP to an ABSENT task gate =========== *
     * ljmp 0xA8 (task gate, P=0, DPL0, RPL0): the class and privilege are
     * admissible, so the oracle reaches switch_tss_ra's gate presence check:
     * #NP(gate selector) = #NP(0xA8). The presence-only failure of this
     * family -- proves case 19 below is a PRECEDENCE result, not a blanket
     * #GP on absent task gates.                                             */
    STAGE   (SLOTS+14*12), c18_done
    .byte   0xEA
    .long   0
    .word   0x00A8
c18_done:
    CHECK   11, 0xA8, 0

    /* ===== case 19: JMP to an ABSENT task gate with RPL > gate DPL ======== *
     * ljmp 0x00AB (the same P=0 task gate, selector RPL cranked to 3): the
     * gate's DPL(0) < RPL(3) -> #GP(selector) BEFORE the gate's presence is
     * consulted. #GP(0xA8) (RPL cleared in the error code), NOT #NP.
     * Presence-first would #NP.                                             */
    STAGE   (SLOTS+15*12), c19_done
    .byte   0xEA
    .long   0
    .word   0x00AB
c19_done:
    CHECK   13, 0xA8, 0

    /* ============== case 8 (ACCEPTED control): direct JMP conforming ====== *
     * ljmp to the CONFORMING DPL0 segment: DPL(0) <= CPL(0), so the transfer
     * is LEGAL -- conf_ok runs, sets its sentinel, and jumps back. Proves the
     * validator is not a blanket reject (the test is not vacuous).          */
    .byte   0xEA
    .long   conf_ok - 0xF0000
    .word   0x0068
c8_back:

    /* ============== case 9 (ACCEPTED control): RETF same-level ============ *
     * An ordinary same-privilege far CALL/RETF round trip: callee9 sets its
     * sentinel and lret's back through the pushed frame. The H-02 staged-ESP
     * machinery must COMMIT the advance on an accept.                         */
    .byte   0x9A
    .long   callee9
    .word   0x0008
    movl    $0x9CAC9CAC, 0x00002024     /* "case 9 returned via the frame" */

    /* ============== case 10 (ACCEPTED control): JMP to a valid TSS ======== *
     * ljmp to TSS2 (available, DPL0, in the GDT, limit 0x67): a legal task
     * switch (ptask's shape). task2 continues the test. HEAD and the fix
     * agree here -- this is the control that keeps the reject cases honest:
     * the TSS path itself works, only the validation was missing.            */
    ljmp    $0x70, $0

    /* ============================ task2 (CPL0) ============================ *
     * Entered by the ACCEPTED case-10 switch. Record the busy bytes (proof
     * the accepted switch toggled them AND that the rejected TSS transfers of
     * cases 3 and 4 wrote NOTHING), then transfer DOWN to CPL3 for the cases
     * that need DPL < CPL.                                                   */
    .align 16
    .global task2
task2:
    movzbl  0x0000052D, %eax            /* TSS1 access: 0x89 (busy CLEARED by the JMP) */
    movl    %eax, 0x00002000
    movzbl  0x00000575, %eax            /* TSS2 access: 0x8B (busy SET) */
    movl    %eax, 0x00002004
    movzbl  0x0000053D, %eax            /* TSS_A access: 0x89 (case 3 wrote NOTHING) */
    movl    %eax, 0x00002008
    movzbl  0x00003405, %eax            /* LDT-TSS access: 0x89 (case 4 wrote NOTHING) */
    movl    %eax, 0x0000200C

    /* transfer DOWN to CPL3 via the outer RETF (pjmpgate's mechanism) */
    pushl   $0x00000023                 /* SS  = ring-3 data, RPL 3 */
    pushl   $0x00005000                 /* ESP = the ring-3 stack */
    pushl   $0x0000001B                 /* CS  = ring-3 code, RPL 3 */
    pushl   $r3_entry                   /* EIP */
    lret

    /* ============================ ring 3 ================================== */
    .global r3_entry
r3_entry:
    /* The outer RETF NULLED DS/ES/FS/GS (DPL 0 < CPL 3) -- reload DS before
     * any data access (see pjmpgate). */
    movw    $0x23, %ax
    movw    %ax, %ds

    /* ============ case 11: direct JMP, nonconforming DPL != CPL =========== *
     * ljmp to code0 (nonconforming DPL0) from CPL3: DPL(0) != CPL(3) ->
     * #GP(0x08). HEAD accepted it and LOWERED CPL to the selector RPL 0 --
     * the silent privilege escalation the finding names. Cross-privilege #GP:
     * the delivery switches to TSS2's SS0:ESP0 (0x10:0x6800).               */
    STAGE   (SLOTS+7*12), c11_done
    .byte   0xEA
    .long   0
    .word   0x0008
c11_done:
    CHECK   13, 0x08, 0

    /* ============== case 12: CALL to a TSS with DPL < CPL ================= *
     * lcall to TSS_C (available, DPL0) from CPL3: a TSS transfer needs DPL >=
     * max(CPL, RPL) -- DPL(0) < CPL(3) -> #GP(0x80). HEAD entered the nesting
     * switch. TSS_C's busy byte must stay 0x89 (read at the exit, ebp).      */
    STAGE   (SLOTS+8*12), c12_done
    .byte   0x9A
    .long   0
    .word   0x0080
c12_done:
    CHECK   13, 0x80, 0

    /* ============== case 13: RETF with popped RPL < CPL =================== *
     * A RETF may not RAISE privilege: popped CS RPL(0) < CPL(3) -> #GP(0x08).
     * HEAD took the same-level path and lowered CPL to 0. ESP must be
     * preserved across the reject (the pops are reads; the advance is staged);
     * compare, then drop the fake frame.                                    */
    STAGE   (SLOTS+9*12), c13_done
    pushl   $0x00000008                 /* popped CS = code0 with RPL 0 */
    pushl   $0x22222222                 /* popped EIP (irrelevant) */
    movl    %esp, PRE_ESP
    lret
c13_done:
    CHECK   13, 0x08, 8

    /* ============ case 20: JMP to an ABSENT TSS with DPL < CPL ============ *
     * ljmp 0x48 (TSS_NP: available 386 TSS, DPL0, P=0) from CPL3: the TSS's
     * DPL(0) < CPL(3) -> #GP(selector) BEFORE the presence bit is consulted
     * (case 5 faults the SAME selector #NP from CPL0 -- the privilege rule,
     * not presence, selects the vector here). #GP(0x48), NOT #NP.
     * Presence-first would #NP.                                             */
    STAGE   (SLOTS+16*12), c20_done
    .byte   0xEA
    .long   0
    .word   0x0048
c20_done:
    CHECK   13, 0x48, 0

    /* ===== case 21 (control): JMP to an ABSENT TSS with admissible DPL ==== *
     * ljmp 0x88 (TSS_D3NP: available 386 TSS, DPL3, P=0) from CPL3:
     * DPL(3) >= max(CPL(3), RPL(0)), so the oracle reaches switch_tss_ra's
     * presence check: #NP(0x88). The presence-only failure of the TSS
     * family -- proves case 20 is a precedence result.                      */
    STAGE   (SLOTS+17*12), c21_done
    .byte   0xEA
    .long   0
    .word   0x0088
c21_done:
    CHECK   11, 0x88, 0

    /* ===== case 22: JMP to a PRESENT task gate with gate DPL < CPL ======== *
     * ljmp 0xB0 (task gate, P=1, DPL0 -> TSS2) from CPL3: the gate's
     * DPL(0) < CPL(3) -> #GP(gate selector) in the oracle's helper, BEFORE
     * switch_tss_ra ever runs. #GP(0xB0). (The admissible form of this
     * transfer is an ACCEPT in the oracle but unimplemented here -- see the
     * header; it is deliberately NOT in this differential image.)           */
    STAGE   (SLOTS+18*12), c22_done
    .byte   0xEA
    .long   0
    .word   0x00B0
c22_done:
    CHECK   13, 0xB0, 0

    /* ===== case 23: CALL through an ABSENT gate with gate DPL < CPL ======= *
     * lcall 0x50 (call gate, P=0, DPL0) from CPL3: the gate's DPL(0) <
     * CPL(3) -> #GP(gate selector) BEFORE the gate's presence is consulted
     * (case 6 faults the SAME gate #NP from CPL0). #GP(0x50), NOT #NP.
     * Presence-first would #NP. The P=0 + admissible-DPL control for this
     * family is case 6 (deduped, not repeated here).                        */
    STAGE   (SLOTS+19*12), c23_done
    .byte   0x9A
    .long   0
    .word   0x0050
c23_done:
    CHECK   13, 0x50, 0

    /* ================= pull the witnesses and exit (CPL3) ================= */
    movzbl  0x00000585, %eax            /* TSS_C access: 0x89 (case 12 wrote NOTHING) */
    movl    %eax, 0x00002010

    /* ---- the rejected transfers wrote NO descriptor byte either: every
     * descriptor the new combined-invalid cases and their controls named
     * (and the absent descriptors of cases 5/6) reads back EXACTLY as
     * built -- no busy-bit set, no type/presence rewrite. 9 checks. ------- */
    ACCCHK  0x0000054D, 0x09            /* 0x48 TSS_NP   (cases 5, 20)  */
    ACCCHK  0x0000058D, 0x69            /* 0x88 TSS_D3NP (case 21)      */
    ACCCHK  0x00000595, 0x8B            /* 0x90 TSS_B    (case 15)      */
    ACCCHK  0x0000059D, 0x0B            /* 0x98 TSS_BNP  (case 14)      */
    ACCCHK  0x000005A5, 0x02            /* 0xA0 LDT_NP   (case 16)      */
    ACCCHK  0x000005AD, 0x05            /* 0xA8 task gate P=0 (18, 19)  */
    ACCCHK  0x000005B5, 0x85            /* 0xB0 task gate P=1 (case 22) */
    ACCCHK  0x00000545, 0x82            /* 0x40 LDT desc (case 17)      */
    ACCCHK  0x00000555, 0x0C            /* 0x50 call gate (cases 6, 23) */

    movl    CNT_NNP, %eax
    shll    $16, %eax
    orl     CNT_NGP, %eax
    movl    %eax, %edi                  /* 0x0004000F */
    movl    CNT_C4OK, %eax
    shll    $16, %eax
    movl    CNT_BUSYOK, %edx
    shll    $8, %edx
    orl     %edx, %eax
    orl     CNT_ESPOK, %eax
    movl    %eax, %esi                  /* 0x00010914 */
    movl    0x00002008, %eax            /* TSS_A acc */
    shll    $8, %eax
    orl     0x00002010, %eax            /* TSS_C acc */
    movl    %eax, %ebp                  /* 0x00008989 */
    movl    0x00002000, %eax            /* TSS1 acc */
    shll    $8, %eax
    orl     0x00002004, %eax            /* TSS2 acc */
    movl    %eax, %ebx                  /* 0x0000898B */
    movl    (SLOTS+0*12+4), %eax        /* case 1 err */
    shll    $16, %eax
    orl     (SLOTS+8*12+4), %eax        /* case 12 err */
    movl    %eax, %ecx                  /* 0x00080080 */

    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                    /* works because CPL==IOPL==3 */
9:  jmp     9b

    /* =================== conforming JMP target (case 8) =================== *
     * Runs in the 0x68 segment (base 0xF0000, so the EIP is the label OFFSET).
     * CS was loaded as 0x68|0 = 0x68 (DPL == CPL, no RPL forcing). Set the
     * sentinel and jump back to the mainline.                               */
    .global conf_ok
conf_ok:
    movw    $0x10, %ax                  /* DS is 0x10 (task1 left it valid) */
    movw    %ax, %ds
    movl    $0xC0F0C0F0, 0x00002020     /* "case 8 transferred: conforming JMP accepted" */
    .byte   0xEA
    .long   c8_back
    .word   0x0008

    /* ======================= same-level callee (case 9) =================== */
    .global callee9
callee9:
    movl    $0xCA11E900, 0x0000201C     /* "case 9 callee ran" */
    lret

    /* ============================ handlers ================================ *
     * gp_entry serves vectors 10 AND 13 (the pssiret precedent -- the case-4
     * vector is QEMU-vs-SDM divergent and is graded from +ven_faultlog);
     * np_entry serves vector 11. The interrupted context's saved CS at
     * 8(%esp) tells the frame shape: RPL 3 => cross-privilege (fault ESP at
     * 16(%esp)); RPL 0 => same-privilege (fault ESP = handler esp + 16).
     * The handler records {vector, error code, ESP-at-fault} into the staged
     * slot, retargets the saved EIP at the staged resume address, drops the
     * error code and IRETs (the cross-privilege form pops ESP/SS itself).
     * DS is flat in both phases (0x10 / 0x23), so absolute stores work.      */
    .align 16
    .global np_entry
np_entry:
    movl    $11, %eax
    jmp     fcommon
    .align 16
    .global gp_entry
gp_entry:
    movl    $13, %eax
fcommon:
    movl    CUR_SLOT, %ebx
    movl    %eax, (%ebx)                /* slot.vec */
    movl    0(%esp), %eax
    movl    %eax, 4(%ebx)               /* slot.err = the frame's error code */
    movl    8(%esp), %eax               /* saved CS of the interrupted context */
    testl   $3, %eax
    jz      1f
    movl    16(%esp), %eax              /* cross-privilege: saved ESP */
    jmp     2f
1:  leal    16(%esp), %eax              /* same-privilege: esp + 4-word frame */
2:  movl    %eax, 8(%ebx)               /* slot.esp = ESP at the fault */
    movl    RESUME_ADR, %eax
    movl    %eax, 4(%esp)               /* saved EIP <- staged resume address */
    addl    $4, %esp                    /* drop the error code */
    iretl

    /* ---- IDT gate builder (EBX = handler offset, EDI = gate slot) ---- */
set_gate0:
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 */
    movl    %eax, (%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax           /* P, DPL0, 32-bit interrupt gate */
    movl    %eax, 4(%edi)
    ret

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
