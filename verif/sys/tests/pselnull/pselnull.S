/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW1_Aug3 R2-C02 — selector nullness, LDT entry 0, and selector error
 * codes (is_null_selector / selector_error).
 *
 * The defect (pre-fix): several paths defined a null selector as
 * selector[15:3] == 0, explicitly ignoring TI, instead of the architectural
 * selector[15:2] == 0 (index 0 AND TI=0, any RPL):
 *   - a legal NULL DS/ES/FS/GS load still performed two GDT[0] reads and
 *     installed GDT[0]'s base/limit/attributes as hidden segment state
 *     (core_seg_ljmp.svh S_SEGLD) -- under paging with GDT[0] on a
 *     non-present page that gratuitous read raises a #PF for an access the
 *     architecture never makes, and with enforcement off a later use
 *     addresses through arbitrary GDT[0] hidden state;
 *   - selectors 0x0004..0x0007, which name LDT entry 0 (a VALID entry), were
 *     treated as null -- a far JMP to a valid LDT-resident code segment via
 *     0x0004 faulted as a null-CS load;
 *   - selector-derived error codes used {selector[15:3],3'b000}, clearing TI
 *     along with RPL -- an out-of-bounds LDT selector faulted with error
 *     code 0x0000 instead of 0x0004;
 *   - an incoming task LDTR of 0x0004 in a TSS was treated as an
     invalid/null LDTR instead of #TS(selector) for the TI violation;
 *   - an incoming task-switch null DATA selector read and staged descriptor
 *     zero (the same gratuitous GDT[0] access under paging).
 * The fix (landed, uncommitted) adds is_null_selector(sel) = (sel[15:2]==0)
 * and selector_error(sel) = sel & 16'hFFFC in ventium_sys_pkg.sv and applies
 * them across S_SEGLD / S_LJMP / S_TSW_*, staging EXPLICIT zeros for null
 * loads with NO descriptor read.
 *
 * THE CASES (one image; paging is enabled halfway through):
 *   pre-paging:
 *   case B  LLDT LDT_B (limit 0x0F), then a far JMP through LDT ENTRY 0
 *           (selector 0x0004) to a valid LDT-resident code segment (base
 *           0xF0000) -- SUCCEEDS; the target sets a sentinel and jumps back.
 *           (HEAD treats 0x0004 as null -> null-CS #GP.)
 *   case C  LLDT LDT_C (limit 0x00), then MOV DS <- 0x0006 (TI=1, index 0,
 *           RPL 2): out of bounds against limit 0 -> #GP with the error code
 *           0x0004 (TI PRESERVED, RPL cleared). (HEAD: 0x0006 is "null" by
 *           the old [15:3] expression, so NO fault at all -- and the old
 *           {sel[15:3],3'b000} error form would give 0x0000 anyway.)
 *   case D  hardware task switch (ljmp to TSS_D) whose incoming LDTR field
 *           is 0x0004 -> #TS(0x0004) (TI violation). (HEAD silently
 *           invalidates the LDT and COMPLETES the switch into task_d.)
 *   paging ON (the GDT's entry 0 -- deliberately NONZERO POISON: a valid
 *           data descriptor with base 0x000A0000 -- sits at linear 0x3FF8 on
 *           page 3, which is NOT PRESENT; the rest of the GDT starts at
 *           0x4000 on present page 4):
 *   case A  MOV DS <- 0x0000 with GDT[0] nonzero AND non-present: NO #PF
 *           (no descriptor read), visible DS=0, then a LEGAL SS-relative
 *           S1 sentinel access. This does NOT prove a hidden DS base of0.
 *           pnullseg independently proves null-DS accesses raise #GP(0).
 *           LEGACY_NULL_USE=1 retains the former unenforced poison-base
 *           diagnostic only; it is never the architectural standard image.
 *   case E  hardware task switch (ljmp to TSS_E, paging stays on) whose
 *           incoming DS is NULL (0x0000) and incoming LDTR is null, with
 *           GDT[0] non-present: the switch completes with NO #PF (explicit
 *           null selectors staged for both), task_e verifies DS=LDTR=0,
 *           and reads S1 legally through SS before restoring valid DS.
 *
 * ORACLE: cases A, B, C, E are implemented identically by QEMU 8.2.2
 * (helper_load_seg / helper_ljmp_protected / switch_tss_ra -- verified in
 * the pinned harness source). Standard A/E no longer access a null DS:
 * QEMU softmmu does not implement per-access null-segment validation and
 * cannot be that access's oracle. Case D remains witness-only (oracle gap):
 * QEMU raises #TS(0x0004) only AFTER committing the whole switch (outgoing
 * save, busy toggle, CR0.TS=1, new task context -- SDM Vol.3A 8.2 step 9/14
 * ordering), while the fix's REVIEW_Aug3 C-06 prevalidation raises it in
 * S_TSW_READ BEFORE any state moves. Both deliver vector 10 with error code
 * 0x0004, but the traces diverge on cr0.TS / ESP / GPRs from the fault on,
 * so no whole-trace differential is possible. The test is therefore a
 * WITNESS gate (the piretgp0 pattern): the golden is generated + validated
 * + self-diffed and step-5g pins QEMU's deviant case-D flow HONESTLY
 * (d_espok == 0, TSS_D busy == 0x8B, TSS1 cleared == 0x89), while the RTL
 * side is graded in step 7w from the final-record GPRs + +ven_faultlog.
 *
 * Memory plan:
 *   GDT  @ 0x00003FF8   entry 0 = POISON (data32, base 0x000A0000, present)
 *                       on page 3 (NON-present under paging); entries 1-8 at
 *                       0x4000-0x4047 on page 4 (present): code0 0x08,
 *                       data0 0x10, LDT_B 0x18 (LDT @ 0x5000 limit 0x0F),
 *                       TSS1 0x20 (@0x6000), TSS_D 0x28 (@0x7000,
 *                       LDTR=0x0004), TSS_E 0x30 (@0x8000, DS=0, LDTR=0,
 *                       CR3=0x11000), LDT_C 0x38 (LDT @ 0x5000 limit 0)
 *   IDT  @ 0x00001000   gates 10 -> ts_entry, 13 -> gp_entry, 14 -> pf_entry
 *   markers @ 0x00002000, slots @ 0x00002800, staging @ 0x00002FE0
 *   LDT  @ 0x00005000   entry 0 = code32 base 0x000F0000 (case B target)
 *   TSS1 @ 0x00006000, TSS_D @ 0x00007000, TSS_E @ 0x00008000
 *   S1   @ 0x00009ABC = 0x0BABE001 (page 9 present)   -- the base-0 sentinel
 *   S2   @ 0x000A9ABC = 0xDEAD9002 (page 0xA9 present) -- the POISON sentinel
 *   PD @ 0x11000, PT0 @ 0x12000 (linearly unmapped; the walker is physical)
 *   CPL0 stack 0x90000, task_d/task_e stacks 0xB000/0xB800 (page 0xB)
 *   image window 0xF0000-0xFFFFF identity
 *
 * EXIT WITNESSES (final-record GPRs; step-7w asserts the RTL values, step-5g
 * pins the GOLDEN's honestly where the oracle ordering differs):
 *   edi = 0x0BABE001  case A: visible DS=0, no #PF on null load, legal
 *         SS-relative S1 read. Neither this nor the sentinel proves DS base.
 *   esi = (b_ok<<16)|0x0004 = 0x00010004  case B's LDT-entry-0 JMP succeeded
 *         (sentinel verified) AND case C's error code is 0x0004 (TI kept)
 *   ebp = (d_espok<<24)|(vec<<16)|err = 0x010A0004 (RTL) / 0x000A0004 (QEMU
 *         golden pin): case D delivered #TS(0x0004); the RTL raised it in
 *         the OUTGOING context (ESP at the fault == the pre-switch ESP,
 *         d_espok=1 -- no state moved), QEMU in the incoming (d_espok=0)
 *   ebx = (TSS_D.acc<<8)|TSS1.acc = 0x0000898B (RTL) / 0x00008B89 (golden
 *         pin): the RTL's rejected switch wrote NO busy bytes; QEMU's
 *         committed-then-faulted switch toggled both
 *   ecx = 0x0BABE001  case E: visible DS=LDTR=0, legal SS-relative S1
 *         read, and no #PF on the paged null-selector task switch
 *
 * NEGATIVE CONTROL (REQUIRED, see manifest.json): the HEAD TB (no R2-C02
 * fix) treats 0x0004/0x0006 as null: case B's JMP faults as a null-CS load
 * (#GP, b_ok=0), case C takes NO fault (silent load of LDT_C entry 0 as DS),
 * case D silently invalidates the incoming LDTR and switches into task_d,
 * and cases A/E read GDT[0] on the non-present page -> #PF -> pf_handler
 * poisons the witnesses and diverts to do_exit. Measured outcomes in
 * manifest.json.
 *
 * GNU-as syntax; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
 */

.set CNT_BOK,   0x00002FE0      /* case B: LDT-entry-0 jump succeeded        */
.set D_ESPOK,   0x00002FE4      /* case D: ESP at the fault == pre-switch    */
.set CUR_SLOT,  0x00002FF0
.set RESUME_ADR,0x00002FF4
.set PRE_ESP,   0x00002FF8
.set SLOTS,     0x00002800      /* 12-byte slots: +0 vec, +4 err, +8 esp     */

.macro STAGE slot, resume
    movl    $(\slot), CUR_SLOT
    movl    $(\resume), RESUME_ADR
    movl    %esp, PRE_ESP
.endm

#ifndef LEGACY_NULL_USE
#define LEGACY_NULL_USE 0
#endif
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

    /* --- the REAL GDT at linear 0x3FF8, lgdt'd once and kept (the PM
     * transition far-jump uses entry 1 at 0x4000). Entry 0 is the POISON
     * descriptor: a valid present data segment with base 0x000A0000 -- the
     * architecture never reads GDT[0], so a correct core never observes it;
     * every pre-fix path that "helpfully" read it for a null selector picks
     * up this base. Under paging entry 0 (0x3FF8-0x3FFF) is on NON-present
     * page 3 while entries 1-8 (0x4000+) are on present page 4.            */
    /* idx0 0x00 POISON data32 base 0x000A0000 (acc 0x92, gran 0xCF) */
    movl    $0x0000FFFF, 0x3FF8
    movl    $0x00CF920A, 0x3FFC
    /* idx1 0x08 code0 flat (0x9A) */      /* @ 0x4000 */
    movl    $0x0000FFFF, 0x4000
    movl    $0x00CF9A00, 0x4004
    /* idx2 0x10 data0 flat (0x92) */
    movl    $0x0000FFFF, 0x4008
    movl    $0x00CF9200, 0x400C
    /* idx3 0x18 LDT_B: base 0x5000, limit 0x0F, acc 0x82 */
    movl    $0x5000000F, 0x4010
    movl    $0x00008200, 0x4014
    /* idx4 0x20 TSS1: base 0x6000, limit 0x67, acc 0x89 */
    movl    $0x60000067, 0x4018
    movl    $0x00008900, 0x401C
    /* idx5 0x28 TSS_D: base 0x7000, limit 0x67, acc 0x89 */
    movl    $0x70000067, 0x4020
    movl    $0x00008900, 0x4024
    /* idx6 0x30 TSS_E: base 0x8000, limit 0x67, acc 0x89 */
    movl    $0x80000067, 0x4028
    movl    $0x00008900, 0x402C
    /* idx7 0x38 LDT_C: base 0x5000, limit 0x00, acc 0x82 */
    movl    $0x50000000, 0x4030
    movl    $0x00008200, 0x4034

    movw    $0x003F, 0x0480             /* GDT limit = 8*8-1 */
    movl    $0x00003FF8, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                  /* opsize-32 ljmp ptr16:32 */
    .long   pm_entry
    .word   0x08

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
    movl    $0x00090000, %esp           /* CPL0 stack */

    /* ---- zero markers 0x2000..0x2028, slots 0x2800..0x2840, staging ------ */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $10, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00002800, %edi
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00002FE0, %edi
    movl    $8, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000: 10 -> ts_entry, 13 -> gp_entry, 14 -> pf_entry ---- */
    movl    $0x00001000, %edi
    movl    $32, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $ts_entry, %ebx
    movl    $0x00001050, %edi           /* #TS */
    call    set_gate0
    movl    $gp_entry, %ebx
    movl    $0x00001068, %edi           /* #GP */
    call    set_gate0
    movl    $pf_entry, %ebx
    movl    $0x00001070, %edi           /* #PF */
    call    set_gate0
    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- LDT @ 0x5000: entry 0 = code32 base 0x000F0000 limit 0xFFFF
     * (byte-gran, D=1, acc 0x9A) -- the case-B far-JMP target; entry 1 =
     * filler data32 flat. ------------------------------------------------- */
    movl    $0x0000FFFF, 0x00005000
    movl    $0x00409A0F, 0x00005004
    movl    $0x0000FFFF, 0x00005008
    movl    $0x00CF9200, 0x0000500C

    /* S1 is the standard legal SS sentinel. S2 is used only by the explicit
     * historical LEGACY_NULL_USE poison-hidden-base diagnostic. */
    movl    $0x0BABE001, 0x00009ABC
    movl    $0xDEAD9002, 0x000A9ABC

    /* ---- TSS1 @ 0x6000 (zeroed; LTR only needs the descriptor) ---------- */
    movl    $0x00006000, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movw    $0x0068, 0x00006066

    /* ---- TSS_D @ 0x7000: the case-D incoming image -- LDTR = 0x0004 (the
     * TI violation). Everything else is a VALID CPL0 flat image, so HEAD's
     * silent-invalidation defect switches in cleanly and runs task_d. ------ */
    movl    $0x00007000, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $task_d,     0x00007020     /* EIP  */
    movl    $0x00000202, 0x00007024     /* EFLAGS */
    movl    $0x0000B000, 0x00007038     /* ESP  */
    movl    $0x00000010, 0x00007048     /* ES   */
    movl    $0x00000008, 0x0000704C     /* CS   */
    movl    $0x00000010, 0x00007050     /* SS   */
    movl    $0x00000010, 0x00007054     /* DS   */
    movl    $0x00000010, 0x00007058     /* FS   */
    movl    $0x00000010, 0x0000705C     /* GS   */
    movl    $0x00000004, 0x00007060     /* LDTR = 0x0004: TI=1 -> #TS(0x0004) */
    movw    $0x0068,     0x00007066

    /* ---- TSS_E @ 0x8000: the case-E incoming image -- DS = NULL (0x0000),
     * LDTR = null, CR3 = 0x11000 (paging STAYS ON). ------------------------ */
    movl    $0x00008000, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $0x00011000, 0x0000801C     /* CR3 (paging persists) */
    movl    $task_e,     0x00008020     /* EIP  */
    movl    $0x00000202, 0x00008024     /* EFLAGS */
    movl    $0x0000B800, 0x00008038     /* ESP  */
    movl    $0x00000010, 0x00008048     /* ES   */
    movl    $0x00000008, 0x0000804C     /* CS   */
    movl    $0x00000010, 0x00008050     /* SS   */
    movl    $0x00000000, 0x00008054     /* DS = NULL: stage zeros, NO GDT[0] read */
    movl    $0x00000010, 0x00008058     /* FS   */
    movl    $0x00000010, 0x0000805C     /* GS   */
    movw    $0x0068,     0x00008066

    movw    $0x0020, %ax
    ltr     %ax

    /* ============ case B: far JMP through LDT ENTRY 0 (0x0004) ============ *
     * 0x0004 is index 0 with TI=1: NOT a null selector -- it names LDT entry
     * 0, an ordinary valid entry (here: code32 base 0xF0000). The JMP must
     * SUCCEED. HEAD's [15:3] null expression treats it as a null CS -> #GP,
     * the handler runs, and the sentinel is never set.                       */
    movw    $0x0018, %ax
    lldt    %ax                         /* LDT_B: limit 0x0F */
    STAGE   (SLOTS+0*12), c_b_done      /* (HEAD-only fault path) */
    .byte   0xEA                        /* ljmp ptr16:32 */
    .long   ldt0_target - 0xF0000
    .word   0x0004
c_b_done:
    cmpl    $0xB000B000, 0x00002008
    jne     1f
    incl    CNT_BOK
1:

    /* ====== case C: out-of-bounds LDT selector -- error code keeps TI ===== *
     * LLDT LDT_C (limit 0x00), then MOV DS <- 0x0006 (TI=1, index 0, RPL 2):
     * the bounds check (0 + 7 > 0) rejects it with #GP(selector_error) =
     * #GP(0x0004) -- TI PRESERVED, only RPL cleared. HEAD takes no fault at
     * all (0x0006 is "null" by the old [15:3] expression), and its
     * {sel[15:3],3'b000} error form would give 0x0000 anyway. DS is
     * unchanged by the rejected load (0x10) in both oracles.                 */
    movw    $0x0038, %ax
    lldt    %ax                         /* LDT_C: limit 0x00 */
    STAGE   (SLOTS+1*12), c_c_done
    movw    $0x0006, %ax
    .global fault_c
fault_c:
    movw    %ax, %ds                    /* #GP(0x0004) */
c_c_done:
    movl    (SLOTS+1*12+4), %eax        /* the handler-recorded error code */
    movl    %eax, 0x0000200C            /* expect 0x00000004 */

    /* ============ case D: incoming task LDTR = 0x0004 -> #TS ============== *
     * A TI=1 "null" is NOT a null LDTR: it is a TI violation -> #TS(0x0004)
     * before any GDT access. The fix's C-06 prevalidation raises it in
     * S_TSW_READ -- no outgoing-busy change, no incoming busy write, no
     * commit: ESP at the fault == the pre-switch ESP and TSS_D/TSS1's busy
     * bytes are UNTOUCHED (0x89 / 0x8B). QEMU raises the same #TS(0x0004) but
     * only AFTER committing the switch (oracle gap -- see the header), so the
     * golden honestly pins d_espok == 0 and the toggled busy bytes. HEAD
     * silently invalidates the LDT and COMPLETES the switch -> task_d runs.  */
    STAGE   (SLOTS+2*12), c_d_done
    .global fault_d
fault_d:
    ljmp    $0x28, $0                   /* task switch to TSS_D */
c_d_done:
    movl    (SLOTS+2*12+0), %eax        /* vec (10 in both oracles) */
    shll    $16, %eax
    orl     (SLOTS+2*12+4), %eax        /* err (0x0004 in both oracles) */
    movl    %eax, 0x00002010            /* expect 0x000A0004 */
    /* d_espok: ESP at the fault == the pre-switch ESP (outgoing-context
     * fault -- nothing moved). 1 in the RTL, 0 in the QEMU golden. */
    movl    (SLOTS+2*12+8), %eax
    cmpl    PRE_ESP, %eax
    jne     1f
    cmpl    PRE_ESP, %esp
    jne     1f
    incl    D_ESPOK
1:
    movzbl  0x00004025, %eax            /* TSS_D access byte */
    movl    %eax, 0x00002014            /* RTL 0x89 (untouched) / golden 0x8B */
    movzbl  0x0000401D, %eax            /* TSS1 access byte */
    movl    %eax, 0x00002018            /* RTL 0x8B (untouched) / golden 0x89 */

    /* ==================== build the page tables ============================ *
     * PT0 @ phys 0x12000: identity, P|RW supervisor. Page 3 (GDT entry 0 at
     * 0x3FF8) is left ABSENT -- the whole point of cases A and E. The PD/PT
     * pages themselves stay linearly unmapped (the walker is physical).      */
    movl    $0x00012000, %edi
    movl    $0x00001003, 4(%edi)        /* page 1: IDT */
    movl    $0x00002003, 8(%edi)        /* page 2: markers */
    movl    $0x00004003, 16(%edi)       /* page 4: GDT entries 1-8 */
    movl    $0x00005003, 20(%edi)       /* page 5: LDT */
    movl    $0x00006003, 24(%edi)       /* page 6: TSS1 */
    movl    $0x00007003, 28(%edi)       /* page 7: TSS_D */
    movl    $0x00008003, 32(%edi)       /* page 8: TSS_E */
    movl    $0x00009003, 36(%edi)       /* page 9: S1 */
    movl    $0x0000B003, 44(%edi)       /* page 0xB: task_d/task_e stacks */
    movl    $0x00090003, 0x240(%edi)    /* page 0x90: CPL0 stack */
    movl    $0x000A9003, 0x2A4(%edi)    /* page 0xA9: S2 (poison target) */
    movl    $0x000123C0, %edi           /* &PT0[0xF0] */
    movl    $0x000F0003, %eax           /* identity the image window */
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x00012003, 0x00011000     /* PD[0] -> PT0 */

    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0                  /* CR0.PG=1: paging ON */

    /* Case A: visible null load succeeds without reading nonpresent GDT[0].
     * The STANDARD sentinel read/store uses valid SS, not unusable DS. */
    xorl    %eax, %eax
    .global null_load_a
null_load_a:
    movw    %ax, %ds                    /* NULL selector: no descriptor read */
#if LEGACY_NULL_USE
    movl    0x00009ABC, %eax            /* DS-relative: base(0) + 0x9ABC = S1 */
    movl    %eax, 0x00002000            /* expect 0x0BABE001 */
#else
    movw    %ds, %ax
    testw   %ax, %ax
    jnz     null_visible_bad
    movl    %ss:0x00009ABC, %eax
    movl    %eax, %ss:0x00002000
#endif
    movw    $0x10, %ax
    movw    %ax, %ds                    /* restore a valid DS */
    movl    $0xC0C0C0C0, 0x00002004     /* "null DS load completed, no #PF" */

    /* ====== case E: paged task switch, incoming DS null, GDT[0] absent ==== *
     * ljmp to TSS_E: the incoming DS is NULL -- the fix stages explicit zeros
     * with NO GDT[0] read (tsw_seg_null), and the null incoming LDTR stages
     * the invalid LDT the same way, so the whole switch touches only PRESENT
     * pages and completes. HEAD reads GDT[0] at linear 0x3FF8 for the null
     * DS -> #PF mid-switch -> pf_entry. task_e starts with unusable null DS. */
    ljmp    $0x30, $0                   /* TASK SWITCH to TSS_E */

    /* Case E: verify visible DS=LDTR=0, legal SS bookkeeping, then restore
     * valid DS. No standard data access depends on a null hidden base. */
    .align 16
    .global task_e
task_e:
#if LEGACY_NULL_USE
    movl    0x00009ABC, %eax            /* via the staged null DS: S1 */
    movl    %eax, 0x00002020            /* expect 0x0BABE001 */
    movl    $0xE0E0E0E0, 0x00002024     /* "paged switch, null DS, no #PF" */
#else
    movw    %ds, %ax
    testw   %ax, %ax
    jnz     null_visible_bad
    sldt    %ax
    testw   %ax, %ax
    jnz     null_visible_bad
    movl    %ss:0x00009ABC, %eax
    movl    %eax, %ss:0x00002020
    movl    $0xE0E0E0E0, %ss:0x00002024
    movw    $0x10, %ax
    movw    %ax, %ds
#endif

    /* ===================== pull the witnesses and exit ===================== */
    .align 16
    .global do_exit
do_exit:
    movl    0x00002000, %edi            /* A: visible null load + legal S1 */
    movl    CNT_BOK, %eax
    shll    $16, %eax
    orl     0x0000200C, %eax
    movl    %eax, %esi                  /* (b_ok<<16)|case C err = 0x00010004 */
    movl    D_ESPOK, %eax
    shll    $24, %eax
    orl     0x00002010, %eax
    movl    %eax, %ebp                  /* (d_espok<<24)|(vec<<16)|err */
    movl    0x00002014, %eax
    shll    $8, %eax
    orl     0x00002018, %eax
    movl    %eax, %ebx                  /* (TSS_D.acc<<8)|TSS1.acc */
    movl    0x00002020, %ecx            /* E: null DS/LDTR + legal S1 */

    movl    $0x42, %eax
    .global exit_port
exit_port:
    movw    $0xF4, %dx
    .global exit_out
exit_out:
    outb    %al, %dx
hang1:
    hlt
    jmp     hang1

#if !LEGACY_NULL_USE
null_visible_bad:
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    $0, 0x00002000
    movl    $0, 0x00002020
    jmp     do_exit
#endif

    /* ================== case-B target (LDT entry 0 code) ================== *
     * Runs with CS = 0x0004 (base 0xF0000): reached ONLY if the far JMP
     * through LDT entry 0 succeeded. Set the sentinel and jump back.         */
    .align 16
    .global ldt0_target
ldt0_target:
    movw    $0x10, %ax                  /* DS stayed 0x10 through the jump */
    movw    %ax, %ds
    movl    $0xB000B000, 0x00002008     /* "LDT entry 0 far-JMP succeeded" */
    .byte   0xEA
    .long   c_b_done
    .word   0x0008

    /* ================== task_d (HEAD-only continuation) =================== *
     * Reached only when the incoming-LDTR TI violation is silently swallowed
     * (the HEAD defect): the switch "succeeds" with an invalidated LDT. Mark
     * it and exit -- the final witnesses then differ from every expectation. */
    .align 16
    .global task_d
task_d:
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    $0xD00DD00D, 0x00002018     /* "HEAD switched in despite LDTR=0x0004" */
    jmp     do_exit

    /* ============================ handlers ================================ *
     * ts_entry/gp_entry share fcommon (staged slot + resume, pxfer's
     * pattern). All faults in this test are same-privilege CPL0 deliveries:
     * [esp]=err  [esp+4]=EIP  [esp+8]=CS  [esp+12]=EFLAGS, and ESP at the
     * fault = handler esp + 16. DS is flat (or base-0 null) everywhere.      */
    .align 16
    .global ts_entry
ts_entry:
    movl    $10, %eax
    jmp     fcommon
    .align 16
    .global gp_entry
gp_entry:
    movl    $13, %eax
fcommon:
    movl    CUR_SLOT, %ebx
    movl    %eax, (%ebx)                /* slot.vec */
    movl    0(%esp), %eax
    movl    %eax, 4(%ebx)               /* slot.err */
    leal    16(%esp), %eax
    movl    %eax, 8(%ebx)               /* slot.esp = ESP at the fault */
    movl    RESUME_ADR, %eax
    movl    %eax, 4(%esp)               /* saved EIP <- staged resume address */
    addl    $4, %esp                    /* drop the error code */
    iretl

    /* pf_entry (HEAD-only in cases A/E): a null-selector path read GDT[0]
     * on the non-present page. Poison the no-#PF marker and divert to the
     * exit -- the final witnesses then differ from every expectation. In the
     * fixed flow (and in QEMU) this handler NEVER runs. */
    .align 16
    .global pf_entry
pf_entry:
    movl    $0xEEEEEEEE, %ss:0x00002004
    movw    $0x10, %ax
    movw    %ax, %ds                   /* reliable failure path with null DS */
    addl    $4, %esp                    /* drop the #PF error code */
    jmp     do_exit

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

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off
    .word   0xF000
