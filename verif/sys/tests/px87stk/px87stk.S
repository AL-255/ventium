/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * px87stk — REVIEW1_Aug3 R2-H06 architectural regression: the x87 STACK-FAULT
 * matrix (SDM Vol.1 8.5.1 / Table 8-4), self-checked, NO QEMU golden.
 *
 * WHY SELF-CHECKED: QEMU 8.2.2 implements NO x87 stack faults -- fpush()/
 * fpop() in target/i386/tcg/fpu_helper.c never consult fptags, and FPUS_SF is
 * defined (line 59) and used NOWHERE in the i386 target. The oracle diverges
 * from the architecture exactly where this test grades, so the oracle is the
 * SDM, asserted in-guest. (Same situation as the S1..S7 block of
 * run-fenv-gate.sh; this test is the full operation x {masked,unmasked}
 * matrix that block sampled.)
 *
 * WHAT THE RTL UNDER TEST DOES (the R2-H06 contract): VEN_X87_STKFLT enables
 * the stack-fault RESPONSE; DETECTION is always live and ARM-INDEPENDENT (the
 * det_* descriptor in rtl/core/fpu_writeback.sv covers the cycle-mode fast
 * arm -- FK_ARITH / FK_FLDSTI / FK_FLDC / pure-pop FSTP ST(0) -- as well as
 * the S_FEXEC/S_FSTORE slow arm). One fp_commit_allowed gates direct
 * writeback, TOP updates, the VEN_FP_PIPE capture, and deferred writes:
 *   - a push onto a LIVE slot (overflow) or any read of an EMPTY register
 *     (underflow: D8 reg-form arith, FLD ST(i) source, FXCH either side,
 *     compares, stores, single-operand transforms) raises #IS:
 *     FSW IE(bit0)|SF(bit6), C1(bit9) = 1 overflow / 0 underflow;
 *   - MASKED (CW.IM=1, the FNINIT default): the op COMPLETES with the QNaN
 *     real indefinite 0xFFFFC000000000000000 as the result; a compare's
 *     masked answer is unordered (C3=C2=C0=1, C1=0);
 *   - UNMASKED (CW.IM=0): NOTHING commits (register file, tags and TOP
 *     bit-identical), IE|SF recorded, ES|B derived, and #MF (vector 16) is
 *     delivered at the next WAITING FP instruction (H-12's route; the default
 *     build checks FWAIT/FNOP);
 *   - FXAM is DEFINED for an empty register and must NOT fault.
 *
 * THE CASES (FNINIT cleanup between every case; CW=0x037F masked / 0x037E
 * unmasked; distinct integer values via FILD so a shifted or destroyed stack
 * is visible in the readback):
 *   M1 masked   FADD ST0,ST1 with ST1 EMPTY (D8 C1; the cycle-mode FAST-arm
 *               FK_ARITH -- with VEN_FP_PIPE this is the capture/cancel path):
 *               IE|SF, C1=0, TOP unchanged, ST0 <- QNaN indefinite.
 *   M2 masked   FLD ST(1) with an EMPTY source (fast-arm FK_FLDSTI): IE|SF,
 *               C1=0, the push completes with the indefinite as the value,
 *               the one live register preserved underneath. The empty slot is
 *               pre-poisoned with 5.0's bits so a raw-stale-bits push is
 *               caught red-handed.
 *   M3 masked   FXCH %st(1) with an EMPTY partner: IE|SF, C1=0, TOP
 *               unchanged, ST(1)'s tag stays EMPTY. (FXCH's masked DATA is
 *               not pinned by Table 8-4 -- only flags/tags are asserted.)
 *   M4 masked   FCOM %st(1) EMPTY: IE|SF, C1=0, and the masked compare
 *               answer UNORDERED (C3=C2=C0=1), no pop.
 *   M5 masked   FSTP ST(0) on an EMPTY stack (fast-arm pure pop): IE|SF,
 *               C1=0, TOP advances (the masked pop completes).
 *   M6 masked   FCOMPP with exactly ONE live register (pop2 over an empty
 *               ST(1)): IE|SF, C1=0, unordered answer, BOTH pops complete.
 *   M7 masked   push OVERFLOW: 8 x FLD1 (fast-arm FK_FLDC fills the stack)
 *               + a 9th: IE|SF, C1=1, the new ST0 is the indefinite; the push
 *               completes and architecturally destroys the oldest register,
 *               leaving SEVEN surviving 1.0s (all eight survive only in the
 *               SUPPRESSED unmasked case, U7).
 *   U1..U7      the SAME seven operations with CW.IM=0: FSW IE|SF|ES|B set,
 *               C1 per direction, TOP UNCHANGED, and the register file/tags
 *               bit-identical (read back via FISTP/FNSTENV AFTER the pending
 *               exception is cleared); each case then takes #MF exactly once
 *               on FWAIT (handler: count++, FNCLEX, IRET; FWAIT re-runs).
 *   F1/F2       FXAM on an EMPTY register, masked AND unmasked: no IE, no
 *               SF, C3C2C0 = 101 (empty class), and NO #MF on a following
 *               FWAIT (the control -- FXAM is defined for empty).
 *
 * REVIEW_Aug4 A4-H01 EXTENSION (two more case blocks, M8..M14 / U8..U14):
 *   (1) FIXED-ST1 CONSUMERS fault on an EMPTY ST1 (fx_fixed_st1 in
 *       rtl/core/fpu_writeback.sv: FPATAN/FYL2X/FYL2XP1/FSCALE/FPREM take
 *       ST(1) implicitly -- fx_reads_sti alone, keyed on the decoded q_f_sti,
 *       never checked their second operand). This image pins the ones the
 *       canonical TB decodes: FSCALE (D9 FD), FPREM (D9 F8, the iterative
 *       S_FPREM_BUSY engine), FPREM1 (D9 F5) -- ST0 LIVE, ST1 EMPTY:
 *       masked -> ST0 <- QNaN indefinite, IE|SF, C1=0; unmasked -> nothing
 *       commits, IE|SF|ES|B, one #MF at FWAIT. (FPATAN/FYL2X/FYL2XP1 loud-
 *       HALT as d_unknown on this build; they live in px87stk2.S.)
 *   (2) DEFERRED COMMITS carry the issue-time decision (fp_flt_q/
 *       fp_flt_ovf_q -> fp_flt_i replay in the writeback's det_deferred):
 *       - S_FSTORE: FST m32 / FSTP m32 of an EMPTY ST0 -- masked -> the
 *         stored dword is the QNaN32 0xFFC00000 (read back from memory),
 *         IE|SF, C1=0, FSTP's pop completes; unmasked -> NO store (the
 *         destination keeps its pre-poison), no pop, IE|SF|ES|B, one #MF.
 *       - FDIV ST(0),ST(i) with ST1 EMPTY / FSQRT with ST0 EMPTY -- on the
 *         canonical (combinational) build these commit on the S_FEXEC direct
 *         path; on the FP_PIPE/FP_PIPE2 variants (+VEN_SRT_ITER) they commit
 *         deferred in S_FP_BUSY, so the SAME cases grade the deferred replay
 *         there. (The dedicated S_FP_BUSY shapes with both FDIV operand
 *         emptiness forms also live in px87stk2.S.)
 *   M8 masked FSCALE ST0 live ST1 empty   M9 masked FPREM    M10 masked FPREM1
 *   M11 masked FST m32 empty ST0          M12 masked FSTP m32 empty ST0
 *   M13 masked FDIV ST0,ST1 ST1 empty     M14 masked FSQRT ST0 empty
 *   U8..U14: the same seven, unmasked (suppression + one #MF each).
 * New totals: 30 cases, 14 unmasked #MF deliveries.
 *
 * ORACLE: architectural (SDM Vol.1 8.5.1, Table 8-4, FSW layout). NOT a
 * differential test -- QEMU cannot produce any of it (see above).
 *
 * GRADING (two surfaces, one code): every check that fails jumps to the
 * common exit with EDI = the check's unique code (0x42 = PASS). The exit
 * loads ebx = the #MF handler count (want 7), ecx = the completed-case count
 * (want 16), edx = 0x600D600D on pass, then does `out 0xf4` with AL = the
 * code.
 *   - Under QEMU's isa-debug-exit the code leaves as the PROCESS STATUS
 *     ((AL<<1)|1: 133 on pass, a per-check status on failure).
 *   - The RTL TB (cosim_en==0) HALTs on `out 0xf4` with NO retire and no
 *     io_req (core_fetch_decode.svh case 2: the golden trace ends BEFORE the
 *     out), so the RTL side is graded from the FINAL TRACE RECORD's GPRs --
 *     the piretgp0 WITNESS pattern: edi==0x42, ebx==7, ecx==16,
 *     edx==0x600D600D. On failure edi names the failing check directly
 *     (map below).
 * Unexpected #GP/#PF/#DF exit with edi = 0x7D/0x7E/0x7F.
 *
 * CHECK->EXIT-CODE MAP (fail edi; pass = 0x42):
 *   M1  01 flags            02-04 indefinite {lo,mid,hi}
 *   M2  05 flags            06-08 indefinite     09 preserved val   0A final TOP
 *   M3  0B flags            0C ST(1) tag still empty
 *   M4  0D flags+unordered  M5 0E flags+TOP    M6 0F flags+unordered+TOP
 *   M7  10 flags(C1=1)      11-13 indefinite   14-1A seven survivors  1C final TOP=7
 *       (1B retired: an earlier rev wrongly expected the EIGHTH register to
 *       survive a masked overflow -- the completing push destroys it)
 *   U1  1D flags            1E #MF delta       1F ST0 intact
 *   U2  20 flags(TOP held)  21 #MF delta       22 val intact        23 depth was 1
 *   U3  24 flags            25 #MF delta       26 ST0 intact
 *   U4  27 flags(CC clear)  28 #MF delta       29 ST0 intact
 *   U5  2A flags(TOP held)  2B #MF delta       2C tags all empty
 *   U6  2D flags(TOP held)  2E #MF delta       2F val intact        30 depth was 1
 *   U7  31 flags(C1=1)      32 #MF delta       33-3A eight live regs intact
 *   F1  3B FXAM empty: CC=101, no IE/SF (masked CW)
 *   F2  3C FXAM empty: CC=101, no IE/SF/ES/B (unmasked CW)   3D no #MF on FWAIT
 *   A4-H01:
 *   M8  40 flags            41-43 indefinite (FSCALE)
 *   M9  44 flags            45-47 indefinite (FPREM, S_FPREM_BUSY deferred)
 *   M10 48 flags            49-4B indefinite (FPREM1)
 *   M11 4C flags            4D stored dword == 0xFFC00000 (FST m32, S_FSTORE)
 *   M12 4E flags(TOP=1)     4F stored dword == 0xFFC00000 (FSTP m32, pop completes)
 *   M13 50 flags            51-53 indefinite (FDIV ST0,ST1)
 *   M14 54 flags            55-57 indefinite (FSQRT)
 *   U8  58 flags            59 #MF delta       5A ST0 intact
 *   U9  5B flags            5C #MF delta       5D ST0 intact
 *   U10 5E flags            5F #MF delta       60 ST0 intact
 *   U11 61 flags            62 #MF delta       63 dest keeps poison (NO store)
 *   U12 64 flags            65 #MF delta       66 dest keeps poison (NO store/pop)
 *   U13 67 flags            68 #MF delta       69 ST0 intact
 *   U14 6A flags            6B #MF delta       6C tags all empty
 *   70  total #MF count == 14     71 all 30 cases completed
 *
 * NEGATIVE CONTROL (REQUIRED): a PRE-R2-H06 build (HEAD rtl + the STKFLT
 * define) detected operand reads on the SLOW arm only -- in cycle mode the
 * fast-arm cases M1/M2/U1/U2 (FK_ARITH / FK_FLDSTI) go undetected and this
 * image exits with AL 0x01/0x05/0x1D/0x20 instead of 0x42. Measured outcomes
 * in manifest.json.
 *
 * GNU-as syntax; no nasm. Flat 64 KiB -bios image; reset F000:FFF0; protected
 * mode CPL0 flat; own IDT with a #MF (vector 16) gate; CR0.MP|NE set.
 */

.set IDT,      0x00001000
.set GDT,      0x00004000
.set PRE_SW,   0x00002000      /* word: FSW before the faulting op          */
.set POST_SW,  0x00002002      /* word: FSW after  the faulting op          */
.set TBYTE,    0x00002010      /* 10-byte FSTPT readback buffer             */
.set ENV28,    0x00002020      /* 28-byte FNSTENV buffer (TW at +8)         */
.set RDINT,    0x00002060      /* dword FISTP readback buffer               */
.set STORE32,  0x00002064      /* dword FST/FSTP m32 destination (poisoned) */
.set MFCNT,    0x00002080      /* dword: #MF handler entry count            */
.set CASES,    0x00002084      /* dword: completed-case count (30 = all)    */
.set CWCELL,   0x000020C0      /* word: FLDCW source                        */
.set INTTAB,   0x000020D0      /* dd 1..9 (0x20D0..0x20F0)                  */

/* ---- check macros: on mismatch exit isa-debug-exit with AL = code -------- */
.macro CHKL addr, exp, code
    cmpl    $\exp, \addr
    je      991f
    movl    $\code, %edi
    jmp     fail_exit
991:
.endm

.macro CHKW addr, exp, code
    cmpw    $\exp, \addr
    je      991f
    movl    $\code, %edi
    jmp     fail_exit
991:
.endm

/* (FSW at \addr) & \mask == \exp */
.macro CHKSW addr, mask, exp, code
    movzwl  \addr, %eax
    andl    $\mask, %eax
    cmpl    $\exp, %eax
    je      991f
    movl    $\code, %edi
    jmp     fail_exit
991:
.endm

/* TBYTE holds the QNaN real indefinite 0xFFFFC000000000000000 */
.macro CHKINDEF c1, c2, c3
    CHKL    TBYTE,   0x00000000, \c1
    CHKL    TBYTE+4, 0xC0000000, \c2
    CHKW    TBYTE+8, 0xFFFF,     \c3
.endm

/* #MF count advanced by EXACTLY one across the preceding FWAIT (esi = pre) */
.macro CHKMF code
    movl    MFCNT, %eax
    leal    1(%esi), %ebx
    cmpl    %ebx, %eax
    je      991f
    movl    $\code, %edi
    jmp     fail_exit
991:
.endm

.macro CASE_MASKED
    fninit
    movw    $0x037F, CWCELL
    fldcw   CWCELL
.endm

.macro CASE_UNMASKED
    fninit
    movw    $0x037E, CWCELL     /* IM=0: invalid/stack-fault UNMASKED */
    fldcw   CWCELL
.endm

/* ============================ 16-bit entry =============================== */
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

    /* GDT @ 0x4000: null, 0x08 code0 flat, 0x10 data0 flat */
    movl    $0x00000000, 0x4000
    movl    $0x00000000, 0x4004
    movl    $0x0000FFFF, 0x4008
    movl    $0x00CF9A00, 0x400C
    movl    $0x0000FFFF, 0x4010
    movl    $0x00CF9200, 0x4014
    movw    $0x0017, 0x0480
    movl    $0x00004000, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x00000023, %eax           /* PE | MP | NE (internal #MF route) */
    movl    %eax, %cr0

    .byte   0x66, 0xEA                  /* opsize-32 ljmp ptr16:32 */
    .long   pm_entry
    .word   0x08

/* ============================ 32-bit body ================================ */
    .code32
    .section .text32, "ax"
    .global pm_entry
pm_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00009000, %esp

    /* zero scratch 0x2000..0x20FF */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $64, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* integer table 1..9 at INTTAB */
    movl    $INTTAB, %edi
    movl    $1, %eax
    movl    $9, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    incl    %eax
    loop    1b

    /* IDT @ 0x1000: zero all 256 gates, then 8->df, 13->gp, 14->pf, 16->mf */
    movl    $IDT, %edi
    xorl    %eax, %eax
    movl    $512, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $df_entry, %ebx
    movl    $(IDT + 8*8), %edi
    call    set_gate0
    movl    $gp_entry, %ebx
    movl    $(IDT + 13*8), %edi
    call    set_gate0
    movl    $pf_entry, %ebx
    movl    $(IDT + 14*8), %edi
    call    set_gate0
    movl    $mf_entry, %ebx
    movl    $(IDT + 16*8), %edi
    call    set_gate0
    movw    $0x07FF, 0x0490
    movl    $IDT, 0x0492
    lidt    0x0490

    /* ======================= M1: masked FADD ST0,ST1, ST1 EMPTY ========== *
     * The D8 register-form arithmetic -- the cycle-mode FAST-arm FK_ARITH
     * (with VEN_FP_PIPE the deferred-capture path). Reading the EMPTY ST(1)
     * is an underflow #IS; masked, the result in ST0 is the QNaN indefinite. */
    CASE_MASKED
    fildl   (INTTAB+16)                 /* ST0 = 5.0, TOP=7 */
    fadd    %st(1), %st(0)              /* D8 C1: reads EMPTY ST(1) -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x3841, 0x01   /* TOP=7, IE|SF, C1=0, ES=B=0 */
    fstpt   TBYTE                       /* ST0 -> mem (TOP 7->0) */
    CHKINDEF 0x02, 0x03, 0x04
    incl    CASES

    /* ======================= M2: masked FLD ST(1), EMPTY source ========== *
     * Fast-arm FK_FLDSTI. The source read of the EMPTY ST(1) is #IS; masked,
     * the push COMPLETES with the indefinite as the pushed value, and the one
     * live register stays intact underneath. The prologue poisons EVERY slot
     * (incl. fpr[0], which IS ST(1) when TOP=7) with 5.0's bit pattern --
     * FNINIT tags registers empty but never clears the data -- so a core that
     * pushes the RAW STALE SLOT BITS instead of the indefinite is caught with
     * the smoking gun in the readback. */
    fninit
    fildl   (INTTAB+16)                 /* 5.0 -> phys7 (TOP=7) */
    fildl   (INTTAB+16)
    fildl   (INTTAB+16)
    fildl   (INTTAB+16)
    fildl   (INTTAB+16)
    fildl   (INTTAB+16)
    fildl   (INTTAB+16)
    fildl   (INTTAB+16)                 /* 5.0 bits now in phys7..phys0 */
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)                      /* pop all: tags empty, 5.0 bits stay */
    CASE_MASKED
    fildl   (INTTAB+8)                  /* ST0 = 3.0 -> phys7, TOP=7 */
    fld     %st(1)                      /* D9 C1: ST(1)=fpr[0], EMPTY -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x3041, 0x05   /* TOP=6 (push completed), IE|SF, C1=0 */
    fstpt   TBYTE                       /* the pushed value... */
    CHKINDEF 0x06, 0x07, 0x08               /* ...must be the QNaN indefinite */
    fistpl  RDINT                       /* the original ST0 survives */
    CHKL    RDINT, 3, 0x09
    fnstsw  POST_SW
    CHKSW   POST_SW, 0x3800, 0x0000, 0x0A   /* both popped: TOP back to 0 */
    incl    CASES

    /* ======================= M3: masked FXCH %st(1), EMPTY partner ======= *
     * No push/pop transition: flags + TOP + the partner's TAG are the whole
     * contract (Table 8-4 pins no data outcome for an exchange). */
    CASE_MASKED
    fildl   (INTTAB+12)                 /* 4.0, TOP=7 */
    fxch    %st(1)                      /* D9 C9: ST(1) EMPTY -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x3841, 0x0B   /* TOP=7, IE|SF, C1=0 */
    fnstenv ENV28                       /* 28-byte env; TW at +8 */
    movzwl  ENV28+8, %eax
    andl    $0xC003, %eax               /* fpr[7]=ST(0) tag [15:14], fpr[0]=ST(1) [1:0] */
    cmpl    $0x0003, %eax               /* ST(0) VALID (00), ST(1) still EMPTY (11) */
    je      991f
    movl    $0x0C, %edi
    jmp     fail_exit
991:
    incl    CASES

    /* ======================= M4: masked FCOM %st(1), EMPTY =============== *
     * A compare's masked #IS answer is UNORDERED: C3=C2=C0=1, C1=0. No pop. */
    CASE_MASKED
    fildl   (INTTAB+4)                  /* 2.0, TOP=7 */
    fcom    %st(1)                      /* D8 D1: ST(1) EMPTY -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xFFC1, 0x7D41, 0x0D   /* TOP=7 | C3|C2|C0 | SF|IE, C1=0 */
    incl    CASES

    /* ======================= M5: masked FSTP ST(0), EMPTY stack ========== *
     * The fast-arm pure pop (DD D8). Masked: the store of the empty register
     * yields the indefinite into the slot and the pop completes -- TOP moves
     * 0 -> 1. (fenvtest's S3 shape, here in the p* matrix.) */
    CASE_MASKED                         /* empty stack, TOP=0 */
    fstp    %st(0)                      /* pop of EMPTY ST(0) -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0841, 0x0E   /* TOP=1, IE|SF, C1=0 */
    incl    CASES

    /* ======================= M6: masked FCOMPP, ONE live register ======== *
     * Pop2 retires ST(0) AND ST(1); ST(1) is EMPTY. Masked: unordered answer,
     * and BOTH pops complete (TOP 7 -> 1). */
    CASE_MASKED
    fildl   (INTTAB+0)                  /* 1.0, TOP=7 */
    fcompp                              /* pops ST0 (live) + ST1 (EMPTY) */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xFFC1, 0x4D41, 0x0F   /* TOP=1 | C3|C2|C0 | SF|IE, C1=0 */
    incl    CASES

    /* ======================= M7: masked push OVERFLOW ==================== *
     * 8 x FLD1 (fast-arm FK_FLDC) fills the stack (TOP wraps to 0); the 9th
     * push targets a LIVE slot. Masked: IE|SF, C1=1, the pushed value is the
     * indefinite -- and the push COMPLETES, architecturally destroying the
     * oldest register it lands on (that is what the masked response means;
     * the UNMASKED U7 case is the one that must preserve all eight). So the
     * stack afterwards holds the indefinite over SEVEN surviving 1.0s: 8 pops
     * empty it, ending at TOP=7. */
    CASE_MASKED
    fld1
    fld1
    fld1
    fld1
    fld1
    fld1
    fld1
    fld1                                /* 8 pushes: stack FULL, TOP=0 */
    fld1                                /* the 9th -- STACK OVERFLOW */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x3A41, 0x10   /* TOP=7, C1=1, IE|SF */
    fstpt   TBYTE                       /* the overflowed push's value... */
    CHKINDEF 0x11, 0x12, 0x13               /* ...is the QNaN indefinite */
    fistpl  RDINT
    CHKL    RDINT, 1, 0x14
    fistpl  RDINT
    CHKL    RDINT, 1, 0x15
    fistpl  RDINT
    CHKL    RDINT, 1, 0x16
    fistpl  RDINT
    CHKL    RDINT, 1, 0x17
    fistpl  RDINT
    CHKL    RDINT, 1, 0x18
    fistpl  RDINT
    CHKL    RDINT, 1, 0x19
    fistpl  RDINT
    CHKL    RDINT, 1, 0x1A              /* the seven survivors are intact */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0x3800, 0x3800, 0x1C   /* 8 pops from TOP=7: empty, TOP=7 */
    incl    CASES

    /* ======================= U1: UNMASKED FADD ST0,ST1, ST1 EMPTY ======== *
     * Unmasked is a different rule (SDM Vol.1 8.5): the register file and TOP
     * are left UNTOUCHED, IE|SF are recorded (ES|B derive from the unmasked
     * flag), and #MF is delivered at the next waiting FP instruction. */
    CASE_UNMASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    movl    MFCNT, %esi
    fadd    %st(1), %st(0)              /* #IS, UNMASKED -> SUPPRESSED */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x1D   /* TOP=7, IE|SF|ES|B, C1=0 */
    fwait                               /* the pending exception -> #MF */
    CHKMF   0x1E
    fistpl  RDINT                       /* ST0 must STILL be 5.0 (no commit) */
    CHKL    RDINT, 5, 0x1F
    incl    CASES

    /* ======================= U2: UNMASKED FLD ST(1), EMPTY source ======== */
    CASE_UNMASKED
    fildl   (INTTAB+8)                  /* 3.0, TOP=7 */
    movl    MFCNT, %esi
    fld     %st(1)                      /* #IS, suppressed: the push does NOT happen */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x20   /* TOP=7 UNCHANGED, IE|SF|ES|B */
    fwait
    CHKMF   0x21
    fistpl  RDINT                       /* the one live register intact */
    CHKL    RDINT, 3, 0x22
    fnstsw  POST_SW
    CHKSW   POST_SW, 0x3800, 0x0000, 0x23   /* one pop empties it: depth was 1 */
    incl    CASES

    /* ======================= U3: UNMASKED FXCH %st(1), EMPTY partner ===== */
    CASE_UNMASKED
    fildl   (INTTAB+12)                 /* 4.0, TOP=7 */
    movl    MFCNT, %esi
    fxch    %st(1)                      /* #IS, suppressed: no exchange */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x24
    fwait
    CHKMF   0x25
    fistpl  RDINT                       /* ST0 keeps 4.0 -- no raw empty-slot */
    CHKL    RDINT, 4, 0x26                  /* bits were swapped in           */
    incl    CASES

    /* ======================= U4: UNMASKED FCOM %st(1), EMPTY ============= *
     * NOTHING commits -- for a compare that means the condition codes stay
     * CLEAR (the unordered answer is the MASKED response only). */
    CASE_UNMASKED
    fildl   (INTTAB+4)                  /* 2.0, TOP=7 */
    movl    MFCNT, %esi
    fcom    %st(1)                      /* #IS, suppressed */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xFFC1, 0xB8C1, 0x27   /* IE|SF|ES|B, C3C2C1C0 all 0, TOP=7 */
    fwait
    CHKMF   0x28
    fistpl  RDINT
    CHKL    RDINT, 2, 0x29
    incl    CASES

    /* ======================= U5: UNMASKED FSTP ST(0), EMPTY stack ======== */
    CASE_UNMASKED                       /* empty, TOP=0 */
    movl    MFCNT, %esi
    fstp    %st(0)                      /* #IS, suppressed: TOP holds, tags hold */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x2A   /* TOP=0, IE|SF|ES|B */
    fwait
    CHKMF   0x2B
    fnstenv ENV28
    movzwl  ENV28+8, %eax
    cmpl    $0xFFFF, %eax               /* every tag still EMPTY */
    je      991f
    movl    $0x2C, %edi
    jmp     fail_exit
991:
    incl    CASES

    /* ======================= U6: UNMASKED FCOMPP, ONE live register ====== *
     * The pop2-over-one-live shape, unmasked: NEITHER pop happens, the live
     * register survives, TOP holds. */
    CASE_UNMASKED
    fildl   (INTTAB+0)                  /* 1.0, TOP=7 */
    movl    MFCNT, %esi
    fcompp                              /* #IS, suppressed: NO pops */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x2D   /* TOP=7 UNCHANGED */
    fwait
    CHKMF   0x2E
    fistpl  RDINT                       /* the live register survives */
    CHKL    RDINT, 1, 0x2F
    fnstsw  POST_SW
    CHKSW   POST_SW, 0x3800, 0x0000, 0x30   /* and it was the ONLY one */
    incl    CASES

    /* ======================= U7: UNMASKED push OVERFLOW ================== *
     * 8 distinct values fill the stack; the 9th push is SUPPRESSED -- TOP
     * stays 0 and all eight registers are bit-identical afterwards. This is
     * the case the stack fault exists for: an unsuppressed 9th push would
     * DESTROY the live register at the wrapped TOP. */
    CASE_UNMASKED
    fildl   (INTTAB+0)                  /* 1 */
    fildl   (INTTAB+4)                  /* 2 */
    fildl   (INTTAB+8)                  /* 3 */
    fildl   (INTTAB+12)                 /* 4 */
    fildl   (INTTAB+16)                 /* 5 */
    fildl   (INTTAB+20)                 /* 6 */
    fildl   (INTTAB+24)                 /* 7 */
    fildl   (INTTAB+28)                 /* 8 -- stack FULL, TOP=0 */
    movl    MFCNT, %esi
    fildl   (INTTAB+32)                 /* the 9th -- OVERFLOW, suppressed */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x82C1, 0x31   /* TOP=0, C1=1, IE|SF|ES|B */
    fwait
    CHKMF   0x32
    fistpl  RDINT
    CHKL    RDINT, 8, 0x33
    fistpl  RDINT
    CHKL    RDINT, 7, 0x34
    fistpl  RDINT
    CHKL    RDINT, 6, 0x35
    fistpl  RDINT
    CHKL    RDINT, 5, 0x36
    fistpl  RDINT
    CHKL    RDINT, 4, 0x37
    fistpl  RDINT
    CHKL    RDINT, 3, 0x38
    fistpl  RDINT
    CHKL    RDINT, 2, 0x39
    fistpl    RDINT
    CHKL    RDINT, 1, 0x3A              /* all eight intact, ST0-first order */
    incl    CASES

    /* ======================= F1: FXAM on EMPTY, masked CW ================ *
     * FXAM is DEFINED for an empty register (C3C2C0 = 101 = empty class);
     * it must NOT raise #IS. C1 (sign of the stale slot bits) is masked out. */
    CASE_MASKED
    fxam
    fnstsw  POST_SW
    CHKSW   POST_SW, 0x4541, 0x4100, 0x3B   /* C3=1,C2=0,C0=1; SF=IE=0 */
    incl    CASES

    /* ======================= F2: FXAM on EMPTY, UNMASKED CW ============== *
     * The same with IM clear: no fault flags, ES/B stay clear, and a
     * following FWAIT must NOT trap -- there is no pending exception. */
    CASE_UNMASKED
    movl    MFCNT, %esi
    fxam
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xC5C1, 0x4100, 0x3C   /* CC=101, IE=SF=ES=B=0 */
    fwait                               /* must NOT take #MF */
    movl    MFCNT, %eax
    cmpl    %esi, %eax
    je      991f
    movl    $0x3D, %edi
    jmp     fail_exit
991:
    incl    CASES

    /* ======================= M8: masked FSCALE, ST0 live ST1 EMPTY ======== *
     * A4-H01 (1): FSCALE takes its exponent from ST(1) IMPLICITLY (there is no
     * encoded ST(i)) -- fx_reads_sti alone never checked it. Masked: ST0 <-
     * the QNaN indefinite, IE|SF, C1=0, no pop. */
    CASE_MASKED
    fildl   (INTTAB+16)                 /* ST0 = 5.0, TOP=7, ST(1) EMPTY */
    fscale                              /* D9 FD: reads EMPTY ST(1) -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x3841, 0x40   /* TOP=7, IE|SF, C1=0 */
    fstpt   TBYTE
    CHKINDEF 0x41, 0x42, 0x43
    incl    CASES

    /* ======================= M9: masked FPREM, ST0 live ST1 EMPTY ========= *
     * A4-H01 (1)+(2): FPREM's divisor is ST(1); with VEN_FPREM the commit is
     * DEFERRED to the iterative engine's S_FPREM_BUSY done-clock, so this case
     * also pins the fp_flt_q replay for that state. Masked: ST0 <- indefinite. */
    CASE_MASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    fprem                               /* D9 F8: divisor ST(1) EMPTY -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x3841, 0x44   /* TOP=7, IE|SF, C1=0 */
    fstpt   TBYTE
    CHKINDEF 0x45, 0x46, 0x47
    incl    CASES

    /* ======================= M10: masked FPREM1, ST0 live ST1 EMPTY ======= */
    CASE_MASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    fprem1                              /* D9 F5: divisor ST(1) EMPTY -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x3841, 0x48   /* TOP=7, IE|SF, C1=0 */
    fstpt   TBYTE
    CHKINDEF 0x49, 0x4A, 0x4B
    incl    CASES

    /* ======================= M11: masked FST m32, EMPTY ST0 ============== *
     * A4-H01 (2) S_FSTORE: the store commits states after the S_FEXEC
     * decision; the masked response is the QNaN indefinite NARROWED to f32 =
     * 0xFFC00000 -- NOT the stale empty-slot bits. The destination is
     * pre-poisoned so a missing or wrong store is visible. */
    CASE_MASKED                         /* empty stack, TOP=0 */
    movl    $0x0B0B0B0B, STORE32
    fsts    (STORE32)                   /* D9 /2: store of EMPTY ST0 -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0041, 0x4C   /* TOP=0 (no pop), IE|SF, C1=0 */
    CHKL    STORE32, 0xFFC00000, 0x4D       /* the QNaN32, not stale slot bits */
    incl    CASES

    /* ======================= M12: masked FSTP m32, EMPTY ST0 ============= *
     * Same store, and the pop COMPLETES (TOP 0 -> 1). */
    CASE_MASKED                         /* empty stack, TOP=0 */
    movl    $0x0B0B0B0B, STORE32
    fstps   (STORE32)                   /* D9 /3: store+pop of EMPTY ST0 -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0841, 0x4E   /* TOP=1 (pop completed), IE|SF, C1=0 */
    CHKL    STORE32, 0xFFC00000, 0x4F
    incl    CASES

    /* ======================= M13: masked FDIV ST0,ST1, ST1 EMPTY ========= *
     * A4-H01 (2) FDIV: on the canonical (combinational) build this is the
     * S_FEXEC direct path; on the FP_PIPE/FP_PIPE2 variants (+VEN_SRT_ITER)
     * the SAME case commits deferred in S_FP_BUSY. Masked: ST0 <- indefinite. */
    CASE_MASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7, ST(1) EMPTY */
    fdiv    %st(1), %st(0)              /* D8 F1: reads EMPTY ST(1) -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x3841, 0x50   /* TOP=7, IE|SF, C1=0 */
    fstpt   TBYTE
    CHKINDEF 0x51, 0x52, 0x53
    incl    CASES

    /* ======================= M14: masked FSQRT, EMPTY ST0 ================ *
     * Direct path canonically, deferred S_FP_BUSY on the SRT_ITER variants. */
    CASE_MASKED                         /* empty stack, TOP=0 */
    fsqrt                               /* D9 FA: operand EMPTY -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0041, 0x54   /* TOP=0, IE|SF, C1=0 */
    fstpt   TBYTE                       /* ST0 <- indefinite, tag VALID */
    CHKINDEF 0x55, 0x56, 0x57
    incl    CASES

    /* ======================= U8: UNMASKED FSCALE, ST0 live ST1 EMPTY ====== *
     * Unmasked: NOTHING commits -- ST0 keeps 5.0, TOP holds, one #MF at FWAIT. */
    CASE_UNMASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    movl    MFCNT, %esi
    fscale                              /* #IS, SUPPRESSED */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x58   /* TOP=7, IE|SF|ES|B, C1=0 */
    fwait
    CHKMF   0x59
    fistpl  RDINT                       /* ST0 must STILL be 5.0 */
    CHKL    RDINT, 5, 0x5A
    incl    CASES

    /* ======================= U9: UNMASKED FPREM, ST0 live ST1 EMPTY ======= *
     * The deferred-engine suppression: without the fp_flt_q replay the
     * S_FPREM_BUSY done-clock commit would write the engine result (computed
     * from empty-slot bits) right over ST0. */
    CASE_UNMASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    movl    MFCNT, %esi
    fprem                               /* #IS, SUPPRESSED (engine result discarded) */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x5B
    fwait
    CHKMF   0x5C
    fistpl  RDINT
    CHKL    RDINT, 5, 0x5D
    incl    CASES

    /* ======================= U10: UNMASKED FPREM1, ST0 live ST1 EMPTY ===== */
    CASE_UNMASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    movl    MFCNT, %esi
    fprem1                              /* #IS, SUPPRESSED */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x5E
    fwait
    CHKMF   0x5F
    fistpl  RDINT
    CHKL    RDINT, 5, 0x60
    incl    CASES

    /* ======================= U11: UNMASKED FST m32, EMPTY ST0 ============ *
     * A4-H01 (2) S_FSTORE: NO store transaction at all -- the destination
     * keeps its poison, and the op retires so the #MF lands at the next
     * waiting FP instruction. */
    CASE_UNMASKED                       /* empty stack, TOP=0 */
    movl    $0x0B0B0B0B, STORE32
    movl    MFCNT, %esi
    fsts    (STORE32)                   /* #IS, SUPPRESSED: no store */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x61   /* TOP=0, IE|SF|ES|B */
    fwait
    CHKMF   0x62
    CHKL    STORE32, 0x0B0B0B0B, 0x63       /* the poison survived */
    incl    CASES

    /* ======================= U12: UNMASKED FSTP m32, EMPTY ST0 =========== *
     * No store AND no pop (TOP holds at 0). */
    CASE_UNMASKED                       /* empty stack, TOP=0 */
    movl    $0x0B0B0B0B, STORE32
    movl    MFCNT, %esi
    fstps   (STORE32)                   /* #IS, SUPPRESSED: no store, no pop */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x64   /* TOP=0 UNCHANGED, IE|SF|ES|B */
    fwait
    CHKMF   0x65
    CHKL    STORE32, 0x0B0B0B0B, 0x66
    incl    CASES

    /* ======================= U13: UNMASKED FDIV ST0,ST1, ST1 EMPTY ======== */
    CASE_UNMASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    movl    MFCNT, %esi
    fdiv    %st(1), %st(0)              /* #IS, SUPPRESSED */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x67
    fwait
    CHKMF   0x68
    fistpl  RDINT
    CHKL    RDINT, 5, 0x69
    incl    CASES

    /* ======================= U14: UNMASKED FSQRT, EMPTY ST0 ============== */
    CASE_UNMASKED                       /* empty stack, TOP=0 */
    movl    MFCNT, %esi
    fsqrt                               /* #IS, SUPPRESSED: ST0 stays EMPTY */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x6A   /* TOP=0, IE|SF|ES|B */
    fwait
    CHKMF   0x6B
    fnstenv ENV28
    movzwl  ENV28+8, %eax
    cmpl    $0xFFFF, %eax               /* every tag still EMPTY */
    je      991f
    movl    $0x6C, %edi
    jmp     fail_exit
991:
    incl    CASES

    /* ======================= final cross-checks + PASS =================== */
    CHKL    MFCNT, 14, 0x70             /* exactly one #MF per unmasked case */
    CHKL    CASES, 30, 0x71             /* every case ran to completion */

    movl    $0x42, %edi                 /* PASS code */
    movl    $0x600D600D, %edx           /* pass magic */
    jmp     fail_exit

/* ============================ handlers ================================== *
 * mf_entry: the deferred-x87-exception delivery. Count, FNCLEX (clears the
 * pending IE/SF/ES/B so the re-executed FWAIT completes), IRET. #MF is a
 * fault with NO error code; the pushed EIP is the FWAIT itself, which re-runs
 * clean after the clear. */
    .align 16
    .global mf_entry
mf_entry:
    incl    MFCNT
    fnclex
    iretl

    /* Unexpected faults: exit with a distinctive code (the run is over). */
    .align 16
    .global df_entry
df_entry:
    movl    $0x7F, %edi
    jmp     fail_exit
    .align 16
    .global gp_entry
gp_entry:
    movl    $0x7D, %edi
    jmp     fail_exit
    .align 16
    .global pf_entry
pf_entry:
    movl    $0x7E, %edi
    jmp     fail_exit

    /* Common exit. EDI = the check code (0x42 = PASS, else the failing check's
     * AL -- see the map in the header). The RTL TB (cosim_en==0) HALTs on the
     * out 0xf4 with NO retire and no io_req (core_fetch_decode.svh case 2), so
     * RTL-side grading reads the FINAL TRACE RECORD's GPRs -- the piretgp0
     * WITNESS pattern:
     *   edi = the code (0x42 on pass)   ebx = #MF handler entries (want 7)
     *   ecx = completed cases (want 16) edx = 0x600D600D pass magic
     * Under QEMU's isa-debug-exit the SAME code leaves as the process status
     * ((AL<<1)|1, so 133 on pass) -- AL below carries edi[7:0]. */
    .align 16
    .global fail_exit
fail_exit:
    movl    MFCNT, %ebx
    movl    CASES, %ecx
    movl    %edi, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

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

/* ===================== 16-bit reset stub @ 0xFFF0 ======================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off
    .word   0xF000
