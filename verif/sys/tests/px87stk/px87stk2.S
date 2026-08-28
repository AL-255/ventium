/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * px87stk2 — REVIEW_Aug4 A4-H01, SECOND image: the variant-only cases of the
 * x87 stack-fault matrix extension, self-checked, NO QEMU golden (QEMU 8.2.2
 * implements no x87 stack faults at all -- see px87stk.S). This image runs
 * ONLY on the obj_dir_x87stk_tr variant TB
 * (+define+VEN_TRANSCENDENTAL +define+VEN_SRT_ITER +define+VEN_FPREM):
 *   - the transcendental fixed-ST1 consumers FPATAN (D9 F3) / FYL2X (D9 F1) /
 *     FYL2XP1 (D9 F9) loud-HALT as d_unknown on the default build
 *     (VEN_TRANSCENDENTAL gates their decode), and
 *   - the S_FP_BUSY DEFERRED commit shapes need VEN_SRT_ITER so FDIV/FSQRT
 *     hand off to the iterative engine and commit in S_FP_BUSY (on the
 *     canonical combinational build px87stk.S's M13/M14/U13/U14 already cover
 *     the direct S_FEXEC path).
 *
 * THE CASES (FNINIT cleanup between every case; CW=0x037F masked / 0x037E
 * unmasked). Grading = px87stk's witness pattern: edi = check code (0x42 =
 * pass), ebx = #MF count (want 6), ecx = completed cases (want 12),
 * edx = 0x600D600D pass magic. Check->exit-code map (fail edi; pass = 0x42):
 *
 *   TM1 masked   FPATAN ST0 live ST1 EMPTY: ST(1) <- QNaN indefinite, the pop
 *                COMPLETES (TOP 7->0), IE|SF, C1=0 -- 01 flags, 02-04 indef
 *   TM2 masked   FYL2X   same shape -- 05 flags, 06-08 indef
 *   TM3 masked   FYL2XP1 same shape -- 09 flags, 0A-0C indef
 *   TU1..TU3     the same three UNMASKED: NOTHING commits (ST0 intact, no
 *                pop -- one pop afterwards empties the stack), IE|SF|ES|B,
 *                one #MF at FWAIT -- 0D/11/15 flags, 0E/12/16 #MF,
 *                0F/13/17 ST0 intact, 10/14/18 depth was 1
 *   DM1 masked   FDIV ST0,ST1 with ST1 EMPTY (deferred S_FP_BUSY): ST0 <-
 *                indefinite, IE|SF, C1=0 -- 19 flags, 1A-1C indef
 *   DM2 masked   FDIV ST0,ST1 with ST0 EMPTY (empty stack): ST0 <- indefinite,
 *                tag VALID -- 1D flags, 1E-20 indef
 *   DM3 masked   FSQRT with ST0 EMPTY: ST0 <- indefinite -- 21 flags, 22-24 indef
 *   DU1 unmasked FDIV ST0,ST1 ST1 empty: nothing commits, one #MF --
 *                25 flags, 26 #MF, 27 ST0 intact
 *   DU2 unmasked FDIV ST0 EMPTY: nothing commits (ST0 stays EMPTY), one #MF --
 *                28 flags, 29 #MF, 2A tags all empty
 *   DU3 unmasked FSQRT ST0 EMPTY: same -- 2B flags, 2C #MF, 2D tags all empty
 *   2E  total #MF count == 6      2F all 12 cases completed
 *   7F/7D/7E = unexpected #DF/#GP/#PF.
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
.set MFCNT,    0x00002080      /* dword: #MF handler entry count            */
.set CASES,    0x00002084      /* dword: completed-case count (12 = all)    */
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

    /* ======================= TM1: masked FPATAN, ST0 live ST1 EMPTY ====== *
     * A4-H01 (1): FPATAN takes y=ST(1) IMPLICITLY, writes ST(1) and pops --
     * fx_reads_sti alone, keyed on the decoded q_f_sti, never checked its
     * second operand. With VEN_TRANSCENDENTAL the commit is DEFERRED to the
     * engine's S_TRSC_BUSY done-clock, so this also pins the fp_flt_q replay
     * for that state. Masked: ST(1) <- indefinite, the pop COMPLETES. */
    CASE_MASKED
    fildl   (INTTAB+16)                 /* ST0 = 5.0, TOP=7, ST(1) EMPTY */
    fpatan                              /* D9 F3: reads EMPTY ST(1) -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0041, 0x01   /* TOP=0 (pop completed), IE|SF, C1=0 */
    fstpt   TBYTE                       /* the new ST0 (= old ST(1))... */
    CHKINDEF 0x02, 0x03, 0x04               /* ...is the QNaN indefinite */
    incl    CASES

    /* ======================= TM2: masked FYL2X, ST0 live ST1 EMPTY ======== */
    CASE_MASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    fyl2x                               /* D9 F1: y=ST(1) EMPTY -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0041, 0x05   /* TOP=0, IE|SF, C1=0 */
    fstpt   TBYTE
    CHKINDEF 0x06, 0x07, 0x08
    incl    CASES

    /* ======================= TM3: masked FYL2XP1, ST0 live ST1 EMPTY ====== */
    CASE_MASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    fyl2xp1                             /* D9 F9: y=ST(1) EMPTY -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0041, 0x09   /* TOP=0, IE|SF, C1=0 */
    fstpt   TBYTE
    CHKINDEF 0x0A, 0x0B, 0x0C
    incl    CASES

    /* ======================= TU1: UNMASKED FPATAN, ST0 live ST1 EMPTY ===== *
     * Unmasked: NOTHING commits -- no ST(1) write, NO pop, ST0 keeps 5.0, and
     * exactly one register is live afterwards. One #MF at FWAIT. */
    CASE_UNMASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    movl    MFCNT, %esi
    fpatan                              /* #IS, SUPPRESSED (engine result discarded) */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x0D   /* TOP=7 UNCHANGED, IE|SF|ES|B */
    fwait
    CHKMF   0x0E
    fistpl  RDINT                       /* ST0 must STILL be 5.0 */
    CHKL    RDINT, 5, 0x0F
    fnstsw  POST_SW
    CHKSW   POST_SW, 0x3800, 0x0000, 0x10   /* one pop empties it: no phantom pop/commit */
    incl    CASES

    /* ======================= TU2: UNMASKED FYL2X ========================== */
    CASE_UNMASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    movl    MFCNT, %esi
    fyl2x                               /* #IS, SUPPRESSED */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x11
    fwait
    CHKMF   0x12
    fistpl  RDINT
    CHKL    RDINT, 5, 0x13
    fnstsw  POST_SW
    CHKSW   POST_SW, 0x3800, 0x0000, 0x14
    incl    CASES

    /* ======================= TU3: UNMASKED FYL2XP1 ======================== */
    CASE_UNMASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    movl    MFCNT, %esi
    fyl2xp1                             /* #IS, SUPPRESSED */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x15
    fwait
    CHKMF   0x16
    fistpl  RDINT
    CHKL    RDINT, 5, 0x17
    fnstsw  POST_SW
    CHKSW   POST_SW, 0x3800, 0x0000, 0x18
    incl    CASES

    /* ======================= DM1: masked FDIV ST0,ST1, ST1 EMPTY ========== *
     * A4-H01 (2) S_FP_BUSY: with VEN_SRT_ITER the divide hands off to the
     * iterative engine and commits DEFERRED; the fp_flt_q replay must
     * substitute the masked response (the QNaN indefinite) for engine output
     * computed from empty-slot bits. */
    CASE_MASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7, ST(1) EMPTY */
    fdiv    %st(1), %st(0)              /* D8 F1: reads EMPTY ST(1) -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x3841, 0x19   /* TOP=7, IE|SF, C1=0 */
    fstpt   TBYTE
    CHKINDEF 0x1A, 0x1B, 0x1C
    incl    CASES

    /* ======================= DM2: masked FDIV ST0,ST1, ST0 EMPTY ========== *
     * The other operand-emptiness form: an EMPTY ST0 read (whole stack empty). */
    CASE_MASKED                         /* empty stack, TOP=0 */
    fdiv    %st(1), %st(0)              /* D8 F1: ST(0) EMPTY -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0041, 0x1D   /* TOP=0, IE|SF, C1=0 */
    fstpt   TBYTE                       /* ST0 <- indefinite, tag VALID */
    CHKINDEF 0x1E, 0x1F, 0x20
    incl    CASES

    /* ======================= DM3: masked FSQRT, ST0 EMPTY ================= */
    CASE_MASKED                         /* empty stack, TOP=0 */
    fsqrt                               /* D9 FA: operand EMPTY -> #IS */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0041, 0x21   /* TOP=0, IE|SF, C1=0 */
    fstpt   TBYTE
    CHKINDEF 0x22, 0x23, 0x24
    incl    CASES

    /* ======================= DU1: UNMASKED FDIV ST0,ST1, ST1 EMPTY ======== *
     * The deferred-engine suppression: without the fp_flt_q replay the
     * S_FP_BUSY done-clock commit would write the engine quotient right over
     * ST0. NOTHING commits; one #MF. */
    CASE_UNMASKED
    fildl   (INTTAB+16)                 /* 5.0, TOP=7 */
    movl    MFCNT, %esi
    fdiv    %st(1), %st(0)              /* #IS, SUPPRESSED */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0xB8C1, 0x25
    fwait
    CHKMF   0x26
    fistpl  RDINT
    CHKL    RDINT, 5, 0x27
    incl    CASES

    /* ======================= DU2: UNMASKED FDIV ST0,ST1, ST0 EMPTY ======== */
    CASE_UNMASKED                       /* empty stack, TOP=0 */
    movl    MFCNT, %esi
    fdiv    %st(1), %st(0)              /* #IS, SUPPRESSED: ST0 stays EMPTY */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x28   /* TOP=0, IE|SF|ES|B */
    fwait
    CHKMF   0x29
    fnstenv ENV28
    movzwl  ENV28+8, %eax
    cmpl    $0xFFFF, %eax               /* every tag still EMPTY */
    je      991f
    movl    $0x2A, %edi
    jmp     fail_exit
991:
    incl    CASES

    /* ======================= DU3: UNMASKED FSQRT, ST0 EMPTY =============== */
    CASE_UNMASKED                       /* empty stack, TOP=0 */
    movl    MFCNT, %esi
    fsqrt                               /* #IS, SUPPRESSED */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x2B   /* TOP=0, IE|SF|ES|B */
    fwait
    CHKMF   0x2C
    fnstenv ENV28
    movzwl  ENV28+8, %eax
    cmpl    $0xFFFF, %eax
    je      991f
    movl    $0x2D, %edi
    jmp     fail_exit
991:
    incl    CASES

    /* ======================= final cross-checks + PASS =================== */
    CHKL    MFCNT, 6, 0x2E              /* exactly one #MF per unmasked case */
    CHKL    CASES, 12, 0x2F             /* every case ran to completion */

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
     * out 0xf4 with NO retire and no io_req, so RTL-side grading reads the
     * FINAL TRACE RECORD's GPRs -- the piretgp0 WITNESS pattern:
     *   edi = the code (0x42 on pass)   ebx = #MF handler entries (want 6)
     *   ecx = completed cases (want 12) edx = 0x600D600D pass magic
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
