/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug3 H-02 — a protected same-privilege far RETF whose popped target
 * CS is rejected must fault with ESP UNCHANGED (restartable), and a 16-bit
 * outer RETF must ZERO-EXTEND the popped outer SP word.
 *
 * The defect (core_gpr_wb.svh / core_seg_ljmp.svh, pre-fix):
 *   (a) the same-privilege RETF advanced ESP on the CS-pop acknowledgement,
 *       BEFORE S_LJMP read and validated the target descriptor. A null,
 *       out-of-bounds, non-code, not-present, or wrong-privilege target
 *       therefore faulted with ESP already advanced by 2w+imm -- the RETF was
 *       not restartable. The fix stages the frame and defers the ESP advance
 *       to the target-validated commit (retf_same / retf_commit_w).
 *   (b) the 16-bit OUTER form read the popped outer SP as a DWORD: the frame
 *       there is a word SP followed immediately by a word SS, so the dword
 *       read carried SS into ESP's upper half. The fix zero-extends the SP
 *       word. (pretfoutpg covers the PAGED variant of (b); this test is the
 *       unpaged restartability companion.)
 *
 * QEMU 8.2.2 is the differential oracle: helper_ret_protected (pinned harness
 * tcg/seg_helper.c:1927) pops into LOCALS, validates (null -> #GP(sel);
 * bounds -> #GP(sel); S/type -> #GP(sel); privilege -> #GP(sel); P=0 ->
 * #NP(sel)) and touches env->regs[R_ESP] only at the final SET_ESP, so a
 * rejected target restarts with ESP unchanged -- exactly the fixed behaviour.
 * (QEMU does NOT check the popped EIP against CS.limit on a return, so the
 * offset-past-limit restartability case cannot be graded differentially; it
 * lives in the piretgp0 WITNESS gate instead -- see its manifest.)
 *
 * THE TEST (three cases, no paging):
 *   case A  32-bit same-priv `lret` with popped CS = 0x28, a NOT-PRESENT code
 *           descriptor (RPL0 == CPL): #NP(0x28) with ESP preserved. Witness:
 *           the #NP handler's entry ESP is 24 (0x18) below the pre-frame ESP
 *           (8 bytes of frame + 16 bytes of fault frame); the broken build's
 *           pre-fault ESP advance leaves only 16.
 *   case B  16-bit same-priv `lretw` (0x66 CB) with popped CS = 0x30, a
 *           second NOT-PRESENT code descriptor: #NP(0x30) with SP preserved.
 *           Witness gap 20 (0x14): 4 bytes of word frame + 16 of fault frame.
 *   case C  16-bit OUTER `lretw` CPL0 -> CPL3: word frame IP/CS/SP/SS. The
 *           popped outer SP word 0x4FF0 must be ZERO-EXTENDED into ESP
 *           (0x00004FF0); the dword-read defect installs {SS,SP}=0x00234FF0.
 *           SS must be 0x23. The CPL3 leg records SS:ESP and exits with
 *           CPL==IOPL==3.
 *
 * Memory plan (no paging, no TSS needed -- case C exits directly from CPL3):
 *   GDT  @ 0x00000500   null + code0 0x08 + data0 0x10 + code3 0x18 (0x1B)
 *                       + data3 0x20 (0x23) + code0-NP 0x28 (P=0) + code0-NP 0x30
 *   IDT  @ 0x00001000   #NP(11) -> np_handler, #GP(13) -> gp_handler (0x8E)
 *   markers @ 0x00002000
 *   CPL3 routine copy @ 0x00003000  (a 16-bit IP cannot reach 0xFxxxx)
 *   16-bit frame page @ 0x00004000  (case C word frame)
 *   CPL3 stack @ 0x00080000 ; CPL0 stack @ 0x00090000
 *
 * WITNESSES (marker page, pulled into the GPRs at the CPL3 exit so the
 * golden-vs-RTL differential compares them):
 *   edi = 0x000B000B  both cases delivered #NP (vector 11), not #GP or a stall
 *   esi = 0x00280030  (errA<<16)|errB: both error codes are the popped selector
 *   ebp = 0x00180014  (gapA<<16)|gapB: 24 and 20 -- ESP preserved on both
 *   ebx = 0x00000023  case-C outer SS
 *   ecx = 0x00004FF0  case-C outer ESP, SP word ZERO-EXTENDED (H-02)
 *
 * NEGATIVE CONTROL (REQUIRED, see manifest.json): the HEAD TB advances ESP at
 * the CS-pop, so the case-A/B gaps measure 16/16 instead of 24/20 AND case C
 * installs 0x00234FF0 as ESP: DIVERGENT.
 *
 * GNU-as; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
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

    /* --- build the GDT (7 entries = 56 bytes) at linear 0x0500 ---
     * idx0        null
     * idx1  0x08  code32 flat DPL0            access 0x9A gran 0xCF
     * idx2  0x10  data32 flat DPL0            access 0x92 gran 0xCF
     * idx3  0x18  code32 flat DPL3            access 0xFA gran 0xCF  -> 0x1B
     * idx4  0x20  data32 flat DPL3            access 0xF2 gran 0xCF  -> 0x23
     * idx5  0x28  code32 flat DPL0, P=0       access 0x1A gran 0xCF  (case A)
     * idx6  0x30  code32 flat DPL0, P=0       access 0x1A gran 0xCF  (case B)
     * Access byte = P(7) DPL(6:5) S(4) type(3:0); 0x1A = P=0|S|code.
     */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)        /* idx0 null */
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* idx3 0x18 code3 */
    movl    $0x00CFFA00, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* idx4 0x20 data3 */
    movl    $0x00CFF200, 36(%ebx)
    movl    $0x0000FFFF, 40(%ebx)       /* idx5 0x28 code0, NOT PRESENT */
    movl    $0x00CF1A00, 44(%ebx)
    movl    $0x0000FFFF, 48(%ebx)       /* idx6 0x30 code0, NOT PRESENT */
    movl    $0x00CF1A00, 52(%ebx)

    movw    $0x0037, 0x0480             /* GDT limit = 56-1 = 0x37 (7 entries) */
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
    movl    $0x00090000, %esp           /* CPL0 stack */

    /* zero the marker area 0x2000..0x20C0 (48 dwords) */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $48, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000: #NP(11) -> np_handler, #GP(13) -> gp_handler ----
     * Zero only vectors 0..15 (32 dwords); low RAM resets to 0 (ptask
     * convention). */
    movl    $0x00001000, %edi
    movl    $32, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    movl    $np_handler, %ebx
    movl    $0x00001058, %edi           /* 0x1000 + 11*8 (#NP) */
    call    set_gate0
    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi           /* 0x1000 + 13*8 (#GP) */
    call    set_gate0

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- copy the CPL3 routine to PHYS/LINEAR 0x3000 (case C supplies a
     * WORD IP, so the target EIP must be below 0x10000) ---- */
    movl    $r3_src, %esi
    movl    $0x00003000, %edi
    movl    $(r3_src_end - r3_src + 3)/4, %ecx
1:  movsl
    loop    1b

    /* IOPL = 3 so the CPL3 leg may drive port 0xF4 for the exit. A RETF does
     * NOT restore EFLAGS, so this survives into case C's ring 3. */
    pushfl
    orl     $0x00003000, (%esp)
    popfl

    /* ==================== case A: 32-bit same-priv RETF, CS not-present ==== *
     * Popped CS = 0x28 (idx5 RPL0): present-bit CLEAR -> #NP(0x28). RPL0 ==
     * CPL0 makes it a SAME-privilege return, the path whose ESP advance the
     * defect took early. The fault must arrive with ESP = the value at the
     * lret (S-8), so np_handler's entry ESP is S-8-16 = S-24: gap 24.      */
    movl    %esp, 0x00002078            /* S_A */
    movl    $caseB, 0x00002080          /* staged resume */
    movl    $0x000020A8, 0x00002088     /* where the handler stores entry ESP */
    movl    $0x00002004, 0x00002084     /* where the handler stores the err */
    movl    $0x00002000, 0x00002090     /* where the handler stores the vector */
    pushl   $0x00000028                 /* CS: NOT-PRESENT code descriptor */
    pushl   $0x00000000                 /* EIP (never reached) */
    lret                                /* must #NP(0x28) with ESP preserved */
    /* reached only if the RETF wrongly succeeded */
    movl    $0xBADBAD0A, 0x00002000

    /* ==================== case B: 16-bit same-priv RETF =================== *
     * lretw (0x66 CB): the frame is a WORD IP then a WORD CS. Popped CS =
     * 0x30, also not-present -> #NP(0x30). The 16-bit defect advance is 2w=4,
     * so the gap is 4+16 = 20 when SP is preserved, 16 when it is not.      */
    .align 16
caseB:
    movl    %esp, 0x0000207C            /* S_B */
    movl    $caseC, 0x00002080
    movl    $0x000020AC, 0x00002088
    movl    $0x00002008, 0x00002084
    movl    $0x00002094, 0x00002090
    subl    $4, %esp                    /* word frame: IP@+0, CS@+2 */
    movw    $0x0000, 0(%esp)            /* IP word (never reached) */
    movw    $0x0030, 2(%esp)            /* CS word: NOT-PRESENT code desc */
    .byte   0x66, 0xCB                  /* lretw */
    movl    $0xBADBAD0B, 0x00002094

    /* ==================== case C: 16-bit OUTER RETF ======================= *
     * Word frame at 0x4000: IP@0x4000, CS@0x4002, SP@0x4004, SS@0x4006.
     * `lretw` pops IP/CS then -- because CS.RPL(3) > CPL(0) -- the outer word
     * SP/SS. H-02: the SP word 0x4FF0 must be ZERO-EXTENDED (ESP=0x00004FF0);
     * the dword-read defect installs {SS,SP} = 0x00234FF0.                 */
    .align 16
caseC:
    movw    $0x3000, 0x00004000         /* IP word: r3 runs at linear 0x3000 */
    movw    $0x001B, 0x00004002         /* CS word = ring-3 code RPL 3 */
    movw    $0x4FF0, 0x00004004         /* SP word */
    movw    $0x0023, 0x00004006         /* SS word = ring-3 data RPL 3 */
    movl    $0x00004000, %esp
    .byte   0x66, 0xCB                  /* lretw (16-bit operand-size RETF) */

    movl    $0xBADBAD02, 0x00002010
9:  jmp     9b

    /* ============================ handlers ================================ *
     * np_handler: SAME-PRIVILEGE delivery at CPL0, 4-word frame:
     *   [esp]=err  [esp+4]=EIP  [esp+8]=CS  [esp+12]=EFLAGS.
     * Record the entry ESP (BEFORE anything else moves it -- this is the
     * restartability witness), the error code and the vector through the
     * staged slots, resume the mainline, drop the error code. */
    .align 16
    .global np_handler
np_handler:
    movl    0x00002088, %ebx            /* staged ESP-store slot */
    movl    %esp, (%ebx)                /* handler entry ESP */
    movl    0x00002090, %ebx            /* staged vector slot */
    movl    $11, (%ebx)                 /* #NP */
    movl    0x00002084, %ebx            /* staged error-code slot */
    movl    0(%esp), %eax
    movl    %eax, (%ebx)
    movl    0x00002080, %eax            /* staged resume address */
    movl    %eax, 4(%esp)               /* overwrite the saved EIP */
    addl    $4, %esp                    /* discard the error code */
    iret

    /* gp_handler: unexpected for cases A/B (they must be #NP). Record vector
     * 13 through the same staged slots so a wrong-vector build is identified
     * distinctly (and the differential would diverge on the frame anyway). */
    .align 16
    .global gp_handler
gp_handler:
    movl    0x00002088, %ebx
    movl    %esp, (%ebx)
    movl    0x00002090, %ebx
    movl    $13, (%ebx)
    movl    0x00002084, %ebx
    movl    0(%esp), %eax
    movl    %eax, (%ebx)
    movl    0x00002080, %eax
    movl    %eax, 4(%esp)
    addl    $4, %esp
    iret

    /* ---- IDT gate builder (EBX = handler offset, EDI = gate slot) ---- */
set_gate0:
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax           /* P, DPL0, 32-bit interrupt gate */
    movl    %eax, 4(%edi)
    ret

    /* ===================== CPL3 leg (case C), runs at 0x3000 ==============
     * Entered with SS=0x23, ESP=0x00004FF0 (if H-02's zero-extension is
     * right; 0x00234FF0 if the dword read survived). DS/ES/FS/GS were nulled
     * by the outer RETF (DPL 0 < new CPL 3 -- both oracles do this), so
     * reload DS before ANY data access. SS is read via memory (movw %ss,mem +
     * movzwl) rather than mov r32,sreg: QEMU zero-extends the selector into
     * the 32-bit register while this core preserves the stale upper half -- a
     * REAL but PRE-EXISTING divergence unrelated to H-02, kept out of this
     * test so the diff isolates the RETF fixes (same convention as pretfoutpg). */
    .global r3_src
r3_src:
    movw    $0x23, %ax
    movw    %ax, %ds
    movw    %ss, 0x00002014
    movzwl  0x00002014, %eax
    movl    %eax, 0x0000200C            /* case-C SS (expect 0x23) */
    movl    %esp, 0x00002010            /* case-C ESP (expect 0x00004FF0) */

    /* compute the two restartability gaps: gapA = S_A - espA (want 24=0x18),
     * gapB = S_B - espB (want 20=0x14); pack (gapA<<16)|gapB. */
    movl    0x00002078, %eax
    subl    0x000020A8, %eax            /* gapA */
    shll    $16, %eax
    movl    0x0000207C, %ebx
    subl    0x000020AC, %ebx            /* gapB */
    orl     %ebx, %eax
    movl    %eax, 0x00002018            /* (gapA<<16)|gapB, want 0x00180014 */

    /* pull every witness into the GPRs for the final-record compare.
     * NOTE: the exit clobbers EAX (0x42) and DX (0xF4), so the 32-bit
     * witnesses use edi/esi/ecx/ebp/ebx only and the two error codes are
     * packed into esi. */
    movl    0x00002000, %eax            /* vecA (11) */
    shll    $16, %eax
    orl     0x00002094, %eax            /* vecB (11) */
    movl    %eax, %edi                  /* edi = 0x000B000B */
    movl    0x00002004, %esi            /* errA (0x28) */
    shll    $16, %esi
    orl     0x00002008, %esi            /* esi = (errA<<16)|errB = 0x00280030 */
    movl    0x00002018, %ebp            /* (gapA<<16)|gapB (0x00180014) */
    movl    0x0000200C, %ebx            /* case-C SS (0x23) */
    movl    0x00002010, %ecx            /* case-C ESP (0x00004FF0) */

    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                    /* CPL==IOPL==3 */
9:  jmp     9b
    .global r3_src_end
r3_src_end:

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off                /* 16-bit offset within segment 0xF000 */
    .word   0xF000                      /* segment */
