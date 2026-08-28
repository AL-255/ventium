/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * px87stk3 — the FULL narrowing-store stack-fault matrix, third image of the
 * px87stk family (same harness conventions as px87stk.S / px87stk2.S).
 * Self-checked against SDM Vol.1 8.5.1 / Table 8-4 -- QEMU 8.2.2 implements
 * no x87 stack faults at all, so no differential golden exists.
 *
 * Every decoded narrowing-store form, masked AND unmasked, on an EMPTY ST0:
 *
 *   masked (CW=0x037F): the store COMPLETES with the destination-specific
 *   indefinite, NOT a conversion of the stale empty-slot bits:
 *     FST  m32            -> 0xFFC00000 (QNaN32),            no pop
 *     FSTP m32            -> 0xFFC00000,                     pop (TOP 0->1)
 *     FST  m64            -> 0xFFF8000000000000 (QNaN64),    no pop
 *     FSTP m64            -> 0xFFF8000000000000,             pop
 *     FIST  m16           -> 0x8000 (integer indefinite),    no pop
 *     FISTP m16           -> 0x8000,                         pop
 *     FIST  m32           -> 0x80000000,                     no pop
 *     FISTP m32           -> 0x80000000,                     pop
 *     FISTP m64           -> 0x8000000000000000,             pop
 *     FBSTP m80           -> packed-BCD indefinite,          pop
 *     (memory byte order 00 00 00 00 00 00 00 C0 FF FF -- the value
 *      80'hFFFFC0000000000000 little-endian, the same image the
 *      proven fx_fx_to_bcd / ven_bcd converters produce)
 *   FSW: IE|SF, C1=0, ES=B=0; TOP unchanged for non-popping forms, advanced
 *   exactly once for popping forms.
 *
 *   unmasked (CW=0x037E): NOTHING commits -- the destination keeps its
 *   poison (no bus request is emitted at all), TOP/tags unchanged, FSW
 *   IE|SF|ES|B, and exactly ONE #MF (vector 16) at the next waiting x87
 *   instruction. On the iterative-BCD build the unmasked FBSTP must retire
 *   suppressed WITHOUT launching the BCD engine; on the PS-trap build every
 *   unmasked narrowing store must retire suppressed WITHOUT launching the
 *   PS trap. (Masked stores on those builds run the engine/PS anyway and
 *   discard its output for the destination-specific indefinite at the
 *   store.)
 *
 * Case B1 (after the matrix) pins the suppressed-FBSTP engine launch: an
 * unmasked FBSTP of an empty ST0 retires suppressed, FNCLEX (non-waiting,
 * no FWAIT) clears the pending #MF state, a known +0.0 is loaded, and a
 * second FBSTP to a fresh buffer follows within the engine's ~60-clock busy
 * window. If the suppressed op had launched the engine (converting the stale
 * 1.0 slot bits), the second FBSTP's start would be ignored while busy and it
 * would consume the FIRST op's done/result, storing BCD-1 instead of BCD-0.
 * The in-guest checks require the exact packed-BCD bytes of the NEW value;
 * the gate additionally asserts the +ven_bcdlog engine-start count (one
 * accepted start per VALID FBSTP, zero for the suppressed ones).
 *
 * Slot + destination poisoning: the prologue fills all eight FP slots with
 * 1.0's bits and pops them back out (tags empty, stale bits remain), so a
 * broken masked response that converts the stale slot shows 0x3F800000 / 1 /
 * BCD-1 instead of the indefinite. Every destination cell is poisoned with
 * 0x0B0B0B0B before the store, so a suppressed store is visible too.
 *
 * Instruction palette is deliberately PL-safe so the image also runs on the
 * PS-trap build (whose TB service answers every trap with one fixed
 * computation): FNINIT, FLDCW, FLD1, FSTP ST(0), the stores under test,
 * FNSTSW, FNSTENV, FWAIT, FNCLEX. No FILD, no arithmetic, no FISTP/FSTPT
 * readbacks -- all result checks are integer memory compares.
 *
 * GRADING (the px87stk witness pattern): a failed check exits with edi = the
 * check's code (pass = 0x42); the exit stages ebx = #MF count (want 10),
 * ecx = completed cases (want 21), edx = 0x600D600D. 10 #MF deliveries
 * total, no other vector.
 *
 * CHECK->EXIT-CODE MAP (fail edi; pass = 0x42; 0x7F/0x7D/0x7E = unexpected
 * #DF/#GP/#PF):
 *   M1  FST  m32  masked   01 flags(0x0041)      02 dst==0xFFC00000
 *   M2  FSTP m32  masked   03 flags(0x0841,pop)  04 dst==0xFFC00000
 *   M3  FST  m64  masked   05 flags              06-07 dst==0xFFF8000000000000
 *   M4  FSTP m64  masked   08 flags(pop)         09-0A dst
 *   M5  FIST m16  masked   0B flags              0C dst==0x8000
 *   M6  FISTP m16 masked   0D flags(pop)         0E dst==0x8000
 *   M7  FIST m32  masked   0F flags              10 dst==0x80000000
 *   M8  FISTP m32 masked   11 flags(pop)         12 dst==0x80000000
 *   M9  FISTP m64 masked   13 flags(pop)         14-15 dst==0x8000000000000000
 *   M10 FBSTP     masked   16 flags(pop)         17-19 dst=={0,0xC0000000,0xFFFF}
 *   U1  FST  m32  unmasked 1A flags(0x80C1)      1B #MF  1C poison  1D tags
 *   U2  FSTP m32  unmasked 1E flags              1F #MF  20 poison  21 tags
 *   U3  FST  m64  unmasked 22 flags              23 #MF  24-25 poison 26 tags
 *   U4  FSTP m64  unmasked 27 flags              28 #MF  29-2A poison 2B tags
 *   U5  FIST m16  unmasked 2C flags              2D #MF  2E poison  2F tags
 *   U6  FISTP m16 unmasked 30 flags              31 #MF  32 poison  33 tags
 *   U7  FIST m32  unmasked 34 flags              35 #MF  36 poison  37 tags
 *   U8  FISTP m32 unmasked 38 flags              39 #MF  3A poison  3B tags
 *   U9  FISTP m64 unmasked 3C flags              3D #MF  3E-3F poison 40 tags
 *   U10 FBSTP     unmasked 41 flags              42 #MF  43-45 poison 46 tags
 *   B1  suppressed-FBSTP engine-launch:
 *       49 flags(0x3800: TOP=7 after the pop, nothing else)
 *       4A-4C suppressed dst kept its poison
 *       4D-4F valid dst == packed-BCD +0 (NOT the stale-slot conversion)
 *       50 tags all empty
 *   47 total #MF == 10     48 all 21 cases completed
 *
 * Memory map: POST_SW 0x2002, ENV28 0x2020, MFCNT 0x2040, CASES 0x2044,
 * CWCELL 0x2048; destinations DST32 0x2060, DST32P 0x2064, DST64 0x2070,
 * DST64P 0x2078, DST16 0x2080, DST16P 0x2082, DSTI32 0x2084, DSTI32P 0x2088,
 * DSTI64 0x2090, DSTBCD 0x20A0, DSTBCD2A 0x20B0, DSTBCD2B 0x20C0.
 * GNU-as syntax; no nasm.
 */

.set IDT,      0x00001000
.set GDT,      0x00004000
.set POST_SW,  0x00002002
.set ENV28,    0x00002020
.set MFCNT,    0x00002040
.set CASES,    0x00002044
.set CWCELL,   0x00002048
.set DST32,    0x00002060
.set DST32P,   0x00002064
.set DST64,    0x00002070
.set DST64P,   0x00002078
.set DST16,    0x00002080
.set DST16P,   0x00002082
.set DSTI32,   0x00002084
.set DSTI32P,  0x00002088
.set DSTI64,   0x00002090
.set DSTBCD,   0x000020A0
.set DSTBCD2A, 0x000020B0
.set DSTBCD2B, 0x000020C0

/* ---- check macros (px87stk conventions) -------------------------------- */
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

/* all eight tags still EMPTY (the unmasked cases' no-commit proof) */
.macro CHKTAGS code
    fnstenv ENV28
    movzwl  ENV28+8, %eax
    cmpl    $0xFFFF, %eax
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

.macro POISON1 addr
    movl    $0x0B0B0B0B, \addr
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

    /* poison every FP slot with 1.0's bits: FLD1 x8 (stack fills), FSTP ST(0)
     * x8 (all tags back to EMPTY, the stale 1.0 bits remain in the slots). A
     * masked response that converted the stale slot instead of substituting
     * the indefinite would show 0x3F800000 / 1 / BCD-1 in the destinations. */
    fninit
    fld1
    fld1
    fld1
    fld1
    fld1
    fld1
    fld1
    fld1
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)
    fstp    %st(0)

    /* ======================= M1: masked FST m32, EMPTY ST0 =============== */
    CASE_MASKED
    POISON1 DST32
    fsts    (DST32)                     /* D9 /2 */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0041, 0x01   /* TOP=0 (no pop), IE|SF, C1=0 */
    CHKL    DST32, 0xFFC00000, 0x02
    incl    CASES

    /* ======================= M2: masked FSTP m32, EMPTY ST0 ============== */
    CASE_MASKED
    POISON1 DST32P
    fstps   (DST32P)                    /* D9 /3 */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0841, 0x03   /* TOP=1 (the pop completed) */
    CHKL    DST32P, 0xFFC00000, 0x04
    incl    CASES

    /* ======================= M3: masked FST m64, EMPTY ST0 =============== */
    CASE_MASKED
    POISON1 DST64
    POISON1 DST64+4
    fstl    (DST64)                     /* DD /2 */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0041, 0x05
    CHKL    DST64,   0x00000000, 0x06
    CHKL    DST64+4, 0xFFF80000, 0x07
    incl    CASES

    /* ======================= M4: masked FSTP m64, EMPTY ST0 ============== */
    CASE_MASKED
    POISON1 DST64P
    POISON1 DST64P+4
    fstpl   (DST64P)                    /* DD /3 */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0841, 0x08
    CHKL    DST64P,   0x00000000, 0x09
    CHKL    DST64P+4, 0xFFF80000, 0x0A
    incl    CASES

    /* ======================= M5: masked FIST m16, EMPTY ST0 ============== */
    CASE_MASKED
    POISON1 DST16
    fists   (DST16)                     /* DF /2 */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0041, 0x0B
    CHKW    DST16, 0x8000, 0x0C
    incl    CASES

    /* ======================= M6: masked FISTP m16, EMPTY ST0 ============= */
    CASE_MASKED
    POISON1 DST16P
    fistps  (DST16P)                    /* DF /3 */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0841, 0x0D
    CHKW    DST16P, 0x8000, 0x0E
    incl    CASES

    /* ======================= M7: masked FIST m32, EMPTY ST0 ============== */
    CASE_MASKED
    POISON1 DSTI32
    fistl   (DSTI32)                    /* DB /2 */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0041, 0x0F
    CHKL    DSTI32, 0x80000000, 0x10
    incl    CASES

    /* ======================= M8: masked FISTP m32, EMPTY ST0 ============= */
    CASE_MASKED
    POISON1 DSTI32P
    fistpl  (DSTI32P)                   /* DB /3 */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0841, 0x11
    CHKL    DSTI32P, 0x80000000, 0x12
    incl    CASES

    /* ======================= M9: masked FISTP m64, EMPTY ST0 ============= */
    CASE_MASKED
    POISON1 DSTI64
    POISON1 DSTI64+4
    fistpll (DSTI64)                    /* DF /7 */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0841, 0x13
    CHKL    DSTI64,   0x00000000, 0x14
    CHKL    DSTI64+4, 0x80000000, 0x15
    incl    CASES

    /* ======================= M10: masked FBSTP, EMPTY ST0 ================ *
     * packed-BCD indefinite 80'hFFFFC0000000000000 little-endian in memory:
     * bytes 00 00 00 00 00 00 00 C0 FF FF. */
    CASE_MASKED
    POISON1 DSTBCD
    POISON1 DSTBCD+4
    POISON1 DSTBCD+8
    fbstp   (DSTBCD)                    /* DF /6 */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x0841, 0x16   /* TOP=1 (the pop completed) */
    CHKL    DSTBCD,   0x00000000, 0x17
    CHKL    DSTBCD+4, 0xC0000000, 0x18
    CHKW    DSTBCD+8, 0xFFFF,     0x19
    incl    CASES

    /* ======================= U1: UNMASKED FST m32 ======================== */
    CASE_UNMASKED
    POISON1 DST32
    movl    MFCNT, %esi
    fsts    (DST32)                     /* #IS, SUPPRESSED: no store */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x1A   /* TOP=0, IE|SF|ES|B */
    fwait
    CHKMF   0x1B
    CHKL    DST32, 0x0B0B0B0B, 0x1C
    CHKTAGS 0x1D
    incl    CASES

    /* ======================= U2: UNMASKED FSTP m32 ======================= */
    CASE_UNMASKED
    POISON1 DST32P
    movl    MFCNT, %esi
    fstps   (DST32P)                    /* no store, no pop */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x1E   /* TOP=0 UNCHANGED */
    fwait
    CHKMF   0x1F
    CHKL    DST32P, 0x0B0B0B0B, 0x20
    CHKTAGS 0x21
    incl    CASES

    /* ======================= U3: UNMASKED FST m64 ======================== */
    CASE_UNMASKED
    POISON1 DST64
    POISON1 DST64+4
    movl    MFCNT, %esi
    fstl    (DST64)
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x22
    fwait
    CHKMF   0x23
    CHKL    DST64,   0x0B0B0B0B, 0x24
    CHKL    DST64+4, 0x0B0B0B0B, 0x25
    CHKTAGS 0x26
    incl    CASES

    /* ======================= U4: UNMASKED FSTP m64 ======================= */
    CASE_UNMASKED
    POISON1 DST64P
    POISON1 DST64P+4
    movl    MFCNT, %esi
    fstpl   (DST64P)
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x27
    fwait
    CHKMF   0x28
    CHKL    DST64P,   0x0B0B0B0B, 0x29
    CHKL    DST64P+4, 0x0B0B0B0B, 0x2A
    CHKTAGS 0x2B
    incl    CASES

    /* ======================= U5: UNMASKED FIST m16 ======================= */
    CASE_UNMASKED
    POISON1 DST16
    movl    MFCNT, %esi
    fists   (DST16)
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x2C
    fwait
    CHKMF   0x2D
    CHKL    DST16, 0x0B0B0B0B, 0x2E
    CHKTAGS 0x2F
    incl    CASES

    /* ======================= U6: UNMASKED FISTP m16 ====================== */
    CASE_UNMASKED
    POISON1 DST16P
    movl    MFCNT, %esi
    fistps  (DST16P)
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x30
    fwait
    CHKMF   0x31
    CHKL    DST16P, 0x0B0B0B0B, 0x32
    CHKTAGS 0x33
    incl    CASES

    /* ======================= U7: UNMASKED FIST m32 ======================= */
    CASE_UNMASKED
    POISON1 DSTI32
    movl    MFCNT, %esi
    fistl   (DSTI32)
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x34
    fwait
    CHKMF   0x35
    CHKL    DSTI32, 0x0B0B0B0B, 0x36
    CHKTAGS 0x37
    incl    CASES

    /* ======================= U8: UNMASKED FISTP m32 ====================== */
    CASE_UNMASKED
    POISON1 DSTI32P
    movl    MFCNT, %esi
    fistpl  (DSTI32P)
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x38
    fwait
    CHKMF   0x39
    CHKL    DSTI32P, 0x0B0B0B0B, 0x3A
    CHKTAGS 0x3B
    incl    CASES

    /* ======================= U9: UNMASKED FISTP m64 ====================== */
    CASE_UNMASKED
    POISON1 DSTI64
    POISON1 DSTI64+4
    movl    MFCNT, %esi
    fistpll (DSTI64)
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x3C
    fwait
    CHKMF   0x3D
    CHKL    DSTI64,   0x0B0B0B0B, 0x3E
    CHKL    DSTI64+4, 0x0B0B0B0B, 0x3F
    CHKTAGS 0x40
    incl    CASES

    /* ======================= U10: UNMASKED FBSTP ========================= *
     * On the iterative-BCD build the suppressed op must retire WITHOUT
     * launching the engine; on the PS-trap build WITHOUT launching the trap. */
    CASE_UNMASKED
    POISON1 DSTBCD
    POISON1 DSTBCD+4
    POISON1 DSTBCD+8
    movl    MFCNT, %esi
    fbstp   (DSTBCD)
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x80C1, 0x41    /* TOP=0 (no pop), IE|SF|ES|B */
    fwait
    CHKMF   0x42
    CHKL    DSTBCD,   0x0B0B0B0B, 0x43
    CHKL    DSTBCD+4, 0x0B0B0B0B, 0x44
    CHKW    DSTBCD+8, 0x0B0B,     0x45
    CHKTAGS 0x46
    incl    CASES

    /* ======================= B1: suppressed FBSTP, FNCLEX, valid FBSTP ==== *
     * The suppressed (unmasked, empty-ST0) FBSTP must retire WITHOUT launching
     * the iterative BCD engine in the background. If it did launch, the engine
     * would convert the stale empty-slot bits (1.0 from the prologue poison)
     * and the SECOND FBSTP below -- issued inside the engine's ~60-clock busy
     * window -- would have its start ignored while busy and consume the FIRST
     * op's done/result, storing BCD-1 (dword0 0x00000001) for a ST0 of +0.0.
     * FNCLEX is non-waiting: it clears the pending IE/SF/ES/B WITHOUT taking
     * #MF and WITHOUT an FWAIT, so the reload and the second FBSTP run
     * immediately. The valid FBSTP executes with TOP=6 and REGISTER-INDIRECT
     * addressing (modrm.rm=0): both the ST0 slot and the slot the store path's
     * second-operand read port exposes (fp_st[1], the other FLDZ fill) hold
     * +0.0's bits, so even the PS-trap build -- whose TB service answers every
     * trap with one fixed atan2(second, ST0) computation -- produces an
     * all-zero result for this op, while the suppressed op's engine input (the
     * TOP=0 slot, still holding the prologue's stale 1.0) converts to BCD-1,
     * keeping the case discriminating. */
    CASE_UNMASKED
    POISON1 DSTBCD2A
    POISON1 DSTBCD2A+4
    POISON1 DSTBCD2A+8
    POISON1 DSTBCD2B
    POISON1 DSTBCD2B+4
    POISON1 DSTBCD2B+8
    movl    $DSTBCD2B, %eax
    fbstp   (DSTBCD2A)                  /* suppressed: no store, no pop, IE|SF|ES|B */
    fnclex                              /* clears the pending #MF state, NO trap */
    fldz                                /* ST0 = +0.0 (TOP 0->7) */
    fldz                                /* ST0 = +0.0 (TOP 7->6); ST1 slot also +0.0 */
    fbstp   (%eax)                      /* valid: packed-BCD +0 = ten 0x00 bytes, pop */
    fnstsw  POST_SW
    CHKSW   POST_SW, 0xBAC1, 0x3800, 0x49   /* TOP=7 after the pop, flags clean */
    CHKL    DSTBCD2A,   0x0B0B0B0B, 0x4A    /* the suppressed store never happened */
    CHKL    DSTBCD2A+4, 0x0B0B0B0B, 0x4B
    CHKW    DSTBCD2A+8, 0x0B0B,     0x4C
    CHKL    DSTBCD2B,   0x00000000, 0x4D    /* NOT 0x00000001 (stale-slot BCD-1) */
    CHKL    DSTBCD2B+4, 0x00000000, 0x4E
    CHKW    DSTBCD2B+8, 0x0000,     0x4F
    fstp    %st(0)                      /* drop the surviving +0.0 (TOP 7->0) */
    CHKTAGS 0x50
    incl    CASES

    /* ======================= final cross-checks + PASS =================== */
    CHKL    MFCNT, 10, 0x47             /* exactly one #MF per unmasked case */
    CHKL    CASES, 21, 0x48             /* every case ran to completion */

    movl    $0x42, %edi                 /* PASS code */
    movl    $0x600D600D, %edx           /* pass magic */
    jmp     fail_exit

/* ============================ handlers ================================== *
 * mf_entry: count, FNCLEX (clears the pending IE/SF/ES/B so the re-executed
 * FWAIT completes), IRET. The pushed EIP is the FWAIT itself; it re-runs
 * clean after the clear. */
    .align 16
    .global mf_entry
mf_entry:
    incl    MFCNT
    fnclex
    iretl

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

    /* Common exit. EDI = the check code (0x42 = PASS, else the failing
     * check's code). The RTL TB halts on the out 0xf4 with no retire, so
     * RTL-side grading reads the FINAL TRACE RECORD's GPRs:
     *   edi = the code (0x42 on pass)   ebx = #MF handler entries (want 10)
     *   ecx = completed cases (want 20) edx = 0x600D600D pass magic
     * Under QEMU's isa-debug-exit the same code leaves as the process status
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
