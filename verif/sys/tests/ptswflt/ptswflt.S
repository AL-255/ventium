/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug4 A4-H09 — task-switch PHASE fault injection. docs/tsw-phase-
 * model.md names the RTL's phases; QEMU's switch_tss_ra orders them
 * DIFFERENTLY (verified in the pinned source: it reads the whole incoming
 * TSS FIRST, probes the outgoing TSS endpoints, clears the outgoing busy bit
 * for JMP BEFORE the save, sets the incoming busy bit after, commits
 * TR/CR3/EIP/GPRs, and only THEN validates the incoming LDTR and segment
 * descriptors). Every injection below therefore lands in the pselnull
 * WITNESS-gate class: the golden pins QEMU's honest flow, the RTL is graded
 * by the step-7w final-GPR witnesses + +ven_faultlog; no whole-trace
 * differential is possible. All cases are CPL0 JMP-source switches; paging
 * + WP are ON (the RO injections need WP).
 *
 * PHASE MAP (RTL phase -> what the injection proves):
 *   P1 (S_TSW_SAVE): outgoing TSS image page READ-ONLY. QEMU's outgoing
 *       ENDPOINT PROBE (it writes tr.base+0 and tr.base+limit_max before any
 *       register save) faults first at tr.base+0; the RTL's first save dword
 *       (EIP @ tr.base+0x20) faults at tr.base+0x20. SAME: vector #PF, err
 *       0x003 (P=1,W=1), CR2 page, ZERO save dwords landed, busy bytes
 *       untouched, outgoing context (esp at fault == pre-switch ESP).
 *       DIFFERS: CR2 low bits (0x7000 vs 0x7020) -- folded as CR2 page only.
 *   P2 (S_TSW_READ): incoming TSS image page NOT PRESENT. QEMU faults at the
 *       incoming read BEFORE touching the outgoing task (outgoing EIP slot
 *       stays 0); the RTL's phase-1 save COMPLETES first (outgoing EIP slot
 *       == the ljmp). SAME: #PF, err 0x000 (P=0,W=0), CR2 page, busy
 *       untouched, outgoing context. DIFFERS: the outgoing save stands in
 *       the RTL only (the save-stands flag), CR2 low bits.
 *   P3 (S_TSW_LDT): incoming LDTR names a NOT-PRESENT LDT descriptor
 *       (0x0040) -> #TS(0x0040). QEMU raises it AFTER the whole commit
 *       (outgoing busy cleared 0x89, incoming set 0x8B, TR=TSS_I3, new
 *       task's ESP/EIP in the frame -- pselnull's oracle gap 1); the RTL
 *       raises it in phase 3 with NOTHING moved (espok=1, busy untouched).
 *   P4 (S_TSW_SEG): incoming DS names a SYSTEM (S=0) descriptor (0x0048) ->
 *       #TS(0x0048) in BOTH oracles (QEMU's tss_load_seg S check; a
 *       not-present descriptor would be #NP in QEMU vs #TS in the RTL -- see
 *       manifest oracle_notes). Same post/pre-commit split as P3.
 *   P4b/P4c/P4d (S_TSW_SEG, presence-only failures): incoming CS (0x50),
 *       SS (0x58), DS (0x60) each name a NOT-PRESENT but otherwise
 *       well-formed descriptor (right S, right type, right privilege) ->
 *       #NP(selector) in BOTH oracles: the type/privilege checks precede
 *       presence, and a presence-only failure is #NP, not #TS. The phase
 *       order still splits the context (espok: RTL pre-commit 1, QEMU
 *       post-commit 0) and the busy bytes (untouched vs toggled), but the
 *       VECTOR and error code are uniform.
 *   P4e (combined-invalid control): incoming CS names a NOT-PRESENT *data*
 *       descriptor (0x68): the type check precedes presence in both oracles,
 *       so this is #TS(0x0068), never #NP.
 *   P5a (S_TSW_BUSY, fault ON the incoming busy write): the incoming TSS
 *       DESCRIPTOR lives on a READ-ONLY GDT page. QEMU's order (clear
 *       outgoing busy -> save -> set incoming) faults at the set with the
 *       OUTGOING DESCRIPTOR CLEARED (0x89); the RTL faults at its phase-5
 *       beat 0 with the outgoing descriptor BUSY (0x8B). SAME: #PF err 0x003,
 *       CR2 (QEMU writes the busy DWORD at desc+4; the RTL the busy byte at
 *       desc+5 -- low bits differ), incoming still 0x89, TR=old, save done.
 *   P5b (between the two busy writes): the OUTGOING TSS descriptor on a
 *       READ-ONLY GDT page, the incoming on a writable one. QEMU faults at
 *       its EARLY outgoing-busy clear (before the save): nothing moved,
 *       outgoing STAYS busy (the clear failed). The RTL saves, validates,
 *       sets the incoming busy bit (0x8B), then faults at the outgoing
 *       clear: outgoing STAYS busy (0x8B) and the incoming is busy-but-not-
 *       entered (0x8B) -- exactly the recoverable C-05 state, NEVER a
 *       running task marked available. REACHABILITY ANSWER for the finding's
 *       phase-5(b): YES, reachable in the RTL FSM by paging the two TSS
 *       descriptors onto different GDT pages; QEMU has no analogous interval
 *       (its busy-clear is before the save, its busy-set after it).
 *   P5c (CALL-source back-link fault): lcall to TSS_I11 (a NESTING switch).
 *       The CALL form's phase-5 second beat writes the outgoing TR selector
 *       into the incoming TSS back-link word at offset 0; the incoming image
 *       page (0x1E000) is READ-ONLY, so the store faults: #PF err 0x003,
 *       CR2 = 0x0001E000 in BOTH oracles, pre-commit in BOTH (espok=1),
 *       TR=TSS_RUN2 (the P5c outgoing task, loaded by the P5b prep), EFLAGS.NT
 *       never set, and the outgoing descriptor is NOT
 *       cleared for the CALL form in either oracle. The phase-5 order
 *       differs: QEMU writes the back-link BEFORE its incoming busy-set (the
 *       incoming stays 0x89); this core sets the incoming busy bit at beat 0
 *       (0x8B -- busy-but-not-entered, recoverable).
 *   Controls: intentionally OMITTED -- ptask/ptaskcpl/ptaskpg/pcalltss cover
 *       the clean JMP/CALL/NT-IRET switches differentially (reference, no
 *       duplication).
 *
 * Memory plan (paging ON, WP ON; identity map 0..0x1FFFFF):
 *   GDT @ 0x3FF8 (entry 0 at the page-3 tail, present): 0x08 code0 flat,
 *     0x10 data0 flat, 0x18 TSS_RUN (@0x7000), 0x20 TSS_I1 (@0x9000),
 *     0x28 TSS_I2 (@0xA000), 0x30 TSS_I3 (@0xB000, LDTR=0x0040),
 *     0x38 TSS_I4 (@0xC000, DS=0x0048), 0x40 LDT_NP (P=0), 0x48 LDT_OK
 *     (S=0, present -- the illegal-as-DS descriptor), 0x50 CS_NP (P=0),
 *     0x58 SS_NP (P=0), 0x60 DS_NP (P=0), 0x68 CS_BAD (P=0 data, used as
 *     CS), 0x70 TSS_I7 (@0x1A000), 0x78 TSS_I8 (@0x1B000), 0x80 TSS_I9
 *     (@0x1C000), 0x88 TSS_I10 (@0x1D000), 0x90 TSS_I11 (@0x1E000),
 *     0x1010 TSS_I5 (@0xD000, descriptor on GDT page 0x5000), 0x1018 TSS_I6
 *     (@0xE000), 0x2010 TSS_RUN2 (@0x8000, descriptor on GDT page 0x6000)
 *   IDT @ 0x1000: 10 -> ts_entry, 11 -> np_entry, 13 -> gp_entry,
 *     14 -> pf_entry (all 32-bit CPL0 int gates, pselnull's fcommon pattern)
 *   markers @ 0x2000, slots @ 0x2800 (20B: vec/err/esp/cr2/saved_eip),
 *   staging @ 0x2FF0, PD @ 0x11000, PT0 @ 0x12000
 *   mainline stack 0x15000, incoming-task stacks 0x16000+i*0x800
 *
 * EXIT WITNESSES (step-7w grades the RTL values; the golden pins QEMU's):
 *   edi = (P1 cr2 & ~0xFFF) | P1 err = 0x00007003  (BOTH oracles identical)
 *   esi = (p2_save_stands<<24) | (P2 cr2 & 0xFFFF)
 *         RTL 0x0100A01C / QEMU 0x0000A01C (incoming CR3-slot read)
 *   ebp = P3<<16 | P4, ebx = P4b<<16 | P4c, ecx = P4d<<16 | P4e with a case
 *         half-word = (espok<<15)|(vector<<8)|errcode:
 *         RTL 0x8A408A48 / 0x8B508B58 / 0x8B608A68
 *         QEMU 0x0A400A48 / 0x0B500B58 / 0x0B600A68
 *   edx = (busy6<<26) | (0x0E3<<16) | 0x00F4, busy6 = the six P5 busy bytes'
 *         BUSY bit (acc == 0x8B) as p5a_run,p5a_inc,p5b_inc,p5b_run,p5c_inc,
 *         p5c_run: RTL 0xBCE300F4 / QEMU 0x14E300F4
 *         (p5a_inc is clear in BOTH -- its busy-set write is the one that
 *         faults; p5b_run and p5c_run are busy in BOTH: the outgoing
 *         descriptor NEVER becomes available mid-switch)
 *   eax = (p5c CR2 >> 4 << 8) | 0x42 = 0x001E0042 (BOTH: the back-link store
 *         faults at incoming TSS offset 0)
 * TR-after-P3/P4, raw CR2s, saved EIPs, outgoing image dwords: memory slots
 * documented in manifest.json.
 *
 * GNU-as syntax; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
 */
.set CNT_SLOT,  20
.set CUR_SLOT,  0x00002FF0
.set RESUME_ADR,0x00002FF4
.set PRE_ESP,   0x00002FF8
.set SLOTS,     0x00002800

.macro STAGE slot, resume
    movl    $(\slot), CUR_SLOT
    movl    $(\resume), RESUME_ADR
    movl    %esp, PRE_ESP
.endm

.macro TSSIMG base, tesp
    /* zero a 32-bit TSS image and fill the standard CPL0 flat fields */
    movl    $\base, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $0x00011000, \base+0x1C    /* CR3 (paging persists) */
    movl    $task_trap, \base+0x20     /* EIP (runs only on a COMPLETED switch) */
    movl    $0x00000202, \base+0x24    /* EFLAGS */
    movl    $\tesp, \base+0x38         /* ESP */
    movl    $0x00000010, \base+0x48    /* ES */
    movl    $0x00000008, \base+0x4C    /* CS */
    movl    $0x00000010, \base+0x50    /* SS */
    movl    $0x00000010, \base+0x54    /* DS */
    movl    $0x00000010, \base+0x58    /* FS */
    movl    $0x00000010, \base+0x5C    /* GS */
    movw    $0x0068, \base+0x66        /* I/O map offset */
.endm

    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %ss
    movw    $0x7000, %sp

    /* GDT @ 0x3FF8 (entry 0 = zeros; descriptors above). The high selectors
     * place the P5 TSS descriptors on their own GDT pages:
     * sel 0x1010/0x1018 -> 0x5008/0x5010 (page 5), sel 0x2010 -> 0x6008
     * (page 6). */
    movl    $0x00000000, 0x3FF8
    movl    $0x00000000, 0x3FFC
    movl    $0x0000FFFF, 0x4000        /* 0x08 code0 flat */
    movl    $0x00CF9A00, 0x4004
    movl    $0x0000FFFF, 0x4008        /* 0x10 data0 flat */
    movl    $0x00CF9200, 0x400C
    movl    $0x70000067, 0x4010        /* 0x18 TSS_RUN  @0x7000 */
    movl    $0x00008900, 0x4014
    movl    $0x90000067, 0x4018        /* 0x20 TSS_I1   @0x9000 */
    movl    $0x00008900, 0x401C
    movl    $0xA0000067, 0x4020        /* 0x28 TSS_I2   @0xA000 */
    movl    $0x00008900, 0x4024
    movl    $0xB0000067, 0x4028        /* 0x30 TSS_I3   @0xB000 */
    movl    $0x00008900, 0x402C
    movl    $0xC0000067, 0x4030        /* 0x38 TSS_I4   @0xC000 */
    movl    $0x00008900, 0x4034
    movl    $0xF00000FF, 0x4038        /* 0x40 LDT_NP: P=0, type 2 (P3's LDTR) */
    movl    $0x00000200, 0x403C
    movl    $0xF00000FF, 0x4040        /* 0x48 LDT_OK: P=1, S=0 type 2 -- used */
    movl    $0x00008200, 0x4044        /*      ILLEGALLY as P4's incoming DS */
    /* 0x50 CS_NP: code32 DPL0 base 0xF0000, NOT PRESENT (access 0x1A) --
     * otherwise well-formed: only the presence check can fire (P4b) */
    movl    $0x0000FFFF, 0x4048
    movl    $0x00401A0F, 0x404C
    /* 0x58 SS_NP: data32 DPL0 flat, NOT PRESENT (access 0x12) -- P4c */
    movl    $0x0000FFFF, 0x4050
    movl    $0x00CF1200, 0x4054
    /* 0x60 DS_NP: data32 DPL0 flat, NOT PRESENT (access 0x12) -- P4d */
    movl    $0x0000FFFF, 0x4058
    movl    $0x00CF1200, 0x405C
    /* 0x68 CS_BAD: NOT-PRESENT data32 (access 0x12) used as an incoming CS --
     * the type check precedes presence, so this is #TS not #NP (P4e) */
    movl    $0x0000FFFF, 0x4060
    movl    $0x00CF1200, 0x4064
    movl    $0xA0000067, 0x4068        /* 0x70 TSS_I7  @0x1A000 (CS=0x50) */
    movl    $0x00008901, 0x406C
    movl    $0xB0000067, 0x4070        /* 0x78 TSS_I8  @0x1B000 (SS=0x58) */
    movl    $0x00008901, 0x4074
    movl    $0xC0000067, 0x4078        /* 0x80 TSS_I9  @0x1C000 (DS=0x60) */
    movl    $0x00008901, 0x407C
    movl    $0xD0000067, 0x4080        /* 0x88 TSS_I10 @0x1D000 (CS=0x68) */
    movl    $0x00008901, 0x4084
    movl    $0xE0000067, 0x4088        /* 0x90 TSS_I11 @0x1E000 (P5c incoming) */
    movl    $0x00008901, 0x408C
    movl    $0xD0000067, 0x5008        /* 0x1010 TSS_I5 @0xD000 (GDT page 5) */
    movl    $0x00008900, 0x500C
    movl    $0xE0000067, 0x5010        /* 0x1018 TSS_I6 @0xE000 (GDT page 5) */
    movl    $0x00008900, 0x5014
    movl    $0x80000067, 0x6008        /* 0x2010 TSS_RUN2 @0x8000 (GDT page 6) */
    movl    $0x00008900, 0x600C

    movw    $0x2017, 0x0480            /* GDT limit (covers sel 0x2010+7) */
    movl    $0x00003FF8, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA
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
    movl    $0x00015000, %esp

    /* ---- zero markers 0x2000..0x2080, slots 0x2800..0x28DC, staging ------ */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $32, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00002800, %edi
    movl    $55, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000: 10 -> ts, 11 -> np, 13 -> gp, 14 -> pf ------------- */
    movl    $ts_entry, %ebx
    movl    $0x00001050, %edi
    call    set_gate0
    movl    $np_entry, %ebx
    movl    $0x00001058, %edi
    call    set_gate0
    movl    $gp_entry, %ebx
    movl    $0x00001068, %edi
    call    set_gate0
    movl    $pf_entry, %ebx
    movl    $0x00001070, %edi
    call    set_gate0
    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- the eight TSS images -------------------------------------------- */
    TSSIMG  0x7000, 0x16000            /* TSS_RUN   (outgoing P1-P5a) */
    TSSIMG  0x8000, 0x16800            /* TSS_RUN2  (outgoing P5b) */
    TSSIMG  0x9000, 0x17000            /* TSS_I1    (P1 incoming) */
    TSSIMG  0xA000, 0x17800            /* TSS_I2    (P2 incoming) */
    TSSIMG  0xB000, 0x18000            /* TSS_I3    (P3 incoming) */
    movl    $0x00000040, 0x0000B060    /*   LDTR = 0x0040 -> LDT_NP (P=0) */
    TSSIMG  0xC000, 0x18800            /* TSS_I4    (P4 incoming) */
    movl    $0x00000048, 0x0000C054    /*   DS = 0x0048 -> LDT_OK (S=0) */
    TSSIMG  0xD000, 0x19000            /* TSS_I5    (P5a incoming) */
    TSSIMG  0xE000, 0x19800            /* TSS_I6    (P5b incoming) */
    TSSIMG  0x1A000, 0x16A000          /* TSS_I7    (P4b incoming) */
    movl    $0x00000050, 0x0001A04C    /*   CS = 0x0050 (CS_NP, presence only) */
    TSSIMG  0x1B000, 0x16A000          /* TSS_I8    (P4c incoming) */
    movl    $0x00000058, 0x0001B050    /*   SS = 0x0058 (SS_NP, presence only) */
    TSSIMG  0x1C000, 0x16A000          /* TSS_I9    (P4d incoming) */
    movl    $0x00000060, 0x0001C054    /*   DS = 0x0060 (DS_NP, presence only) */
    TSSIMG  0x1D000, 0x16A000          /* TSS_I10   (P4e incoming) */
    movl    $0x00000068, 0x0001D04C    /*   CS = 0x0068 (not-present DATA:
                                        /*    type ranks before presence) */
    TSSIMG  0x1E000, 0x16A800          /* TSS_I11   (P5c incoming, CALL source) */

    /* ---- page tables: PT0 identity 0..0x1FFFFF, PD; then PG|WP ------------ */
    movl    $0x00012000, %edi
    movl    $0x00000003, %eax
    movl    $512, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x00012003, 0x00011000
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80010000, %eax          /* PG | WP */
    movl    %eax, %cr0

    movw    $0x0018, %ax
    ltr     %ax                        /* TR = TSS_RUN (busy 0x89 -> 0x8B) */

    /* ==================== P1: S_TSW_SAVE -- outgoing page RO ===============
     * QEMU's outgoing endpoint PROBE faults at tr.base+0 (before any save);
     * the RTL's first save dword faults at tr.base+0x20. Both: #PF err 0x003,
     * ZERO dwords landed, busy untouched, outgoing context. */
    movl    $0x00007001, 0x0001201C    /* PTE[7]: present, READ-ONLY */
    invlpg  0x7000
    STAGE   (SLOTS+0*CNT_SLOT), p1_done
    ljmp    $0x20, $0                  /* switch to TSS_I1 */
p1_done:
    movl    $0x00015000, %esp
    movl    (SLOTS+0*CNT_SLOT+12), %eax
    andl    $0xFFFFF000, %eax          /* CR2 page (0x7000 both) */
    orl     (SLOTS+0*CNT_SLOT+4), %eax /* err (0x003 both) */
    movl    %eax, 0x00002000           /* expect 0x00007003 (BOTH oracles) */
    movl    0x00007020, %eax           /* outgoing EIP slot (readable: RO) */
    movl    %eax, 0x00002004           /* expect 0 -- nothing landed (BOTH) */
    movl    $0x00007003, 0x0001201C    /* repair page 7 (P2's RTL save needs it) */
    invlpg  0x7000

    /* ==================== P2: S_TSW_READ -- incoming page NP ===============
     * QEMU faults at the incoming read BEFORE any outgoing effect; the RTL's
     * phase-1 save COMPLETES (outgoing EIP slot == p2_fire). Both: #PF err
     * 0x000, busy untouched, outgoing context. */
    movl    $0x00000000, 0x00012028    /* PTE[0xA] = NOT PRESENT */
    invlpg  0xA000
    STAGE   (SLOTS+1*CNT_SLOT), p2_done
    .global p2_fire
p2_fire:
    ljmp    $0x28, $0                  /* switch to TSS_I2 */
p2_done:
    movl    $0x00015000, %esp
    movl    0x00007020, %eax           /* TSS_RUN EIP slot */
    movl    %eax, 0x00002008           /* RTL: p2_fire / QEMU: 0 (save never ran) */
    movl    (SLOTS+1*CNT_SLOT+12), %eax
    movl    %eax, 0x0000200C           /* P2 CR2 (raw; folded low 16 at exit) */
    movl    $0x0000A003, 0x00012028    /* repair (hygiene) */
    invlpg  0xA000

    /* ==================== P3: S_TSW_LDT -- incoming LDTR not-present =======
     * #TS(0x0040). QEMU raises it AFTER the full commit (espok=0, TSS_RUN
     * cleared 0x89, TSS_I3 set 0x8B, TR=TSS_I3); the RTL in phase 3 with
     * NOTHING moved (espok=1, busy untouched, TR=TSS_RUN). */
    STAGE   (SLOTS+2*CNT_SLOT), p3_done
    ljmp    $0x30, $0                  /* switch to TSS_I3 (LDTR=0x0040) */
p3_done:
    movl    $0x00015000, %esp
    movl    (SLOTS+2*CNT_SLOT+8), %eax
    xorl    %ecx, %ecx
    cmpl    PRE_ESP, %eax
    jne     1f
    movl    $1, %ecx
1:  movl    %ecx, 0x00002010          /* p3 espok: RTL 1 / QEMU 0 */
    movzbl  0x00004015, %eax
    movl    %eax, 0x00002014          /* TSS_RUN acc: RTL 0x8B / QEMU 0x89 */
    movzbl  0x0000402D, %eax
    movl    %eax, 0x00002018          /* TSS_I3 acc: RTL 0x89 / QEMU 0x8B */
    str     %ax
    movzwl  %ax, %eax
    movl    %eax, 0x0000201C          /* TR after: RTL 0x18 / QEMU 0x30 */
    movb    $0x89, 0x00004015         /* restore: TSS_RUN available, TR=RUN */
    movw    $0x0018, %ax
    ltr     %ax

    /* ==================== P4: S_TSW_SEG -- incoming DS is SYSTEM ===========
     * #TS(0x0048) in BOTH oracles (QEMU tss_load_seg S=0 check; a NOT-PRESENT
     * incoming DS would be #NP in QEMU vs #TS in the RTL -- deliberately
     * avoided, see manifest). Same post/pre-commit split as P3. */
    STAGE   (SLOTS+3*CNT_SLOT), p4_done
    ljmp    $0x38, $0                  /* switch to TSS_I4 (DS=0x0048) */
p4_done:
    movl    $0x00015000, %esp
    movl    (SLOTS+3*CNT_SLOT+8), %eax
    xorl    %ecx, %ecx
    cmpl    PRE_ESP, %eax
    jne     1f
    movl    $1, %ecx
1:  movl    %ecx, 0x00002020          /* p4 espok: RTL 1 / QEMU 0 */
    movzbl  0x00004015, %eax
    movl    %eax, 0x00002024          /* TSS_RUN acc: RTL 0x8B / QEMU 0x89 */
    movzbl  0x00004035, %eax
    movl    %eax, 0x00002028          /* TSS_I4 acc: RTL 0x89 / QEMU 0x8B */
    str     %ax
    movzwl  %ax, %eax
    movl    %eax, 0x0000202C          /* TR after: RTL 0x18 / QEMU 0x38 */
    movb    $0x89, 0x00004015
    movw    $0x0018, %ax
    ltr     %ax

    /* ==================== P4b: incoming CS NOT PRESENT =====================
     * The descriptor is otherwise well-formed (S=1, code, DPL0 == RPL0), so
     * only the presence check can fire: #NP(0x0050) in BOTH oracles. The
     * phase order still splits the context (espok). */
    STAGE   (SLOTS+6*CNT_SLOT), p4b_done
    ljmp    $0x70, $0                  /* switch to TSS_I7 (CS=0x50, P=0) */
p4b_done:
    movl    $0x00015000, %esp
    movl    (SLOTS+6*CNT_SLOT+8), %eax
    xorl    %ecx, %ecx
    cmpl    PRE_ESP, %eax
    jne     1f
    movl    $1, %ecx
1:  movl    %ecx, 0x00002050          /* p4b espok: RTL 1 / QEMU 0 */
    movb    $0x89, 0x00004015
    movw    $0x0018, %ax
    ltr     %ax

    /* ==================== P4c: incoming SS NOT PRESENT =====================
     * #NP(0x0058) in both oracles (CS loads first and is valid). */
    STAGE   (SLOTS+7*CNT_SLOT), p4c_done
    ljmp    $0x78, $0                  /* switch to TSS_I8 (SS=0x58, P=0) */
p4c_done:
    movl    $0x00015000, %esp
    movl    (SLOTS+7*CNT_SLOT+8), %eax
    xorl    %ecx, %ecx
    cmpl    PRE_ESP, %eax
    jne     1f
    movl    $1, %ecx
1:  movl    %ecx, 0x00002054          /* p4c espok: RTL 1 / QEMU 0 */
    movb    $0x89, 0x00004015
    movw    $0x0018, %ax
    ltr     %ax

    /* ==================== P4d: incoming DS NOT PRESENT =====================
     * #NP(0x0060) in both oracles (CS/SS/ES load, DS faults). */
    STAGE   (SLOTS+8*CNT_SLOT), p4d_done
    ljmp    $0x80, $0                  /* switch to TSS_I9 (DS=0x60, P=0) */
p4d_done:
    movl    $0x00015000, %esp
    movl    (SLOTS+8*CNT_SLOT+8), %eax
    xorl    %ecx, %ecx
    cmpl    PRE_ESP, %eax
    jne     1f
    movl    $1, %ecx
1:  movl    %ecx, 0x00002058          /* p4d espok: RTL 1 / QEMU 0 */
    movb    $0x89, 0x00004015
    movw    $0x0018, %ax
    ltr     %ax

    /* ============== P4e: combined-invalid control (type + presence) ========
     * Incoming CS names a NOT-PRESENT *data* descriptor: the type check
     * precedes presence in both oracles, so this is #TS(0x0068), never #NP. */
    STAGE   (SLOTS+9*CNT_SLOT), p4e_done
    ljmp    $0x88, $0                  /* switch to TSS_I10 (CS=0x68, bad type) */
p4e_done:
    movl    $0x00015000, %esp
    movl    (SLOTS+9*CNT_SLOT+8), %eax
    xorl    %ecx, %ecx
    cmpl    PRE_ESP, %eax
    jne     1f
    movl    $1, %ecx
1:  movl    %ecx, 0x0000205C          /* p4e espok: RTL 1 / QEMU 0 */
    movb    $0x89, 0x00004015
    movw    $0x0018, %ax
    ltr     %ax

    /* ==================== P5a: fault ON the incoming busy write ============
     * Incoming TSS descriptor on a READ-ONLY GDT page (page 5). QEMU (clear
     * outgoing -> save -> set incoming) faults at the set with TSS_RUN
     * CLEARED (0x89); the RTL faults at phase-5 beat 0 with TSS_RUN BUSY
     * (0x8B). Both: #PF err 0x003, incoming 0x89, TR=TSS_RUN, outgoing
     * context; CR2 low bits differ (dword store at desc+4 vs byte at desc+5). */
    movl    $0x00005001, 0x00012014    /* PTE[5]: present, READ-ONLY */
    invlpg  0x5000
    STAGE   (SLOTS+4*CNT_SLOT), p5a_done
    ljmp    $0x1010, $0                /* switch to TSS_I5 */
p5a_done:
    movl    $0x00015000, %esp
    movzbl  0x00004015, %eax
    movl    %eax, 0x00002030          /* p5a_run: RTL 0x8B / QEMU 0x89 */
    movzbl  0x0000500D, %eax
    movl    %eax, 0x00002034          /* p5a_inc: 0x89 BOTH (set write failed) */
    movl    (SLOTS+4*CNT_SLOT+12), %eax
    movl    %eax, 0x00002038          /* p5a CR2 (raw) */
    movl    $0x00005003, 0x00012014   /* repair page 5 */
    invlpg  0x5000
    /* prep P5b: TSS_RUN2 descriptor available + LTR, then page 6 RO */
    movl    $0x00006003, 0x00012018   /* page 6 RW (hygiene) */
    invlpg  0x6000
    movb    $0x89, 0x0000600D         /* TSS_RUN2 acc = available */
    movw    $0x2010, %ax
    ltr     %ax                       /* TR = TSS_RUN2 (busy -> 0x8B) */
    movl    $0x00006001, 0x00012018   /* PTE[6]: present, READ-ONLY */
    invlpg  0x6000

    /* ==================== P5b: fault BETWEEN the two busy writes ===========
     * Outgoing (TSS_RUN2) descriptor RO, incoming (TSS_I6) writable. QEMU
     * faults at its EARLY busy clear (before the save): nothing moved, both
     * bytes unchanged (0x8B / 0x89). The RTL saves, validates, SETS the
     * incoming busy bit (0x8B), then faults at the outgoing clear: outgoing
     * STAYS busy (0x8B -- never a running task marked available) and the
     * incoming is busy-but-not-entered (the recoverable C-05 state). */
    STAGE   (SLOTS+5*CNT_SLOT), p5b_done
    ljmp    $0x1018, $0                /* switch to TSS_I6 */
p5b_done:
    movl    $0x00015000, %esp
    movzbl  0x00005015, %eax
    movl    %eax, 0x0000203C          /* p5b_inc: RTL 0x8B (set OK) / QEMU 0x89 */
    movzbl  0x0000600D, %eax
    movl    %eax, 0x00002040          /* p5b_run: 0x8B BOTH (clear failed) */
    movl    (SLOTS+5*CNT_SLOT+12), %eax
    movl    %eax, 0x00002044          /* p5b CR2 (raw) */
    movl    $0x00006003, 0x00012018   /* repair page 6 */
    invlpg  0x6000

    /* ==================== P5c: CALL-source BACKLINK write RO ===============
     * lcall to TSS_I11 (a NESTING switch): the CALL form's phase-5 second
     * beat writes the outgoing TR selector into the incoming TSS back-link
     * word at offset 0, and the outgoing descriptor is NOT cleared in either
     * oracle (the caller remains an active task, returned to via NT-IRET).
     * The incoming image page (0x1E000) is READ-ONLY, so the back-link store
     * faults: #PF err 0x003, CR2 = 0x0001E000, BOTH oracles pre-commit
     * (espok=1), TR=TSS_RUN2 (the outgoing task since the P5b prep's LTR),
     * EFLAGS.NT never set. The phase-5 ORDER differs:
     * the pinned emulator writes the back-link BEFORE its incoming busy-set
     * (the incoming stays 0x89), while this core sets the incoming busy bit
     * at beat 0 (0x8B -- busy-but-not-entered, the recoverable state).     */
    movl    $0x0001E001, 0x00012078   /* PTE[0x1E]: present, READ-ONLY */
    invlpg  0x1E000
    STAGE   (SLOTS+10*CNT_SLOT), p5c_done
    .byte   0x9A                       /* lcall ptr16:32 -> TSS_I11 */
    .long   0
    .word   0x0090
p5c_done:
    movl    $0x00015000, %esp
    movzbl  0x0000600D, %eax
    movl    %eax, 0x00002060          /* p5c_run (TSS_RUN2 acc, the P5c OUTGOING
                                       /* task since the P5b prep's LTR): 0x8B
                                       /* BOTH -- CALL never clears the caller */
    movzbl  0x0000408D, %eax
    movl    %eax, 0x00002064          /* p5c_inc (TSS_I11 acc): RTL 0x8B / QEMU 0x89 */
    movl    (SLOTS+10*CNT_SLOT+12), %eax
    movl    %eax, 0x00002068          /* p5c CR2: 0x0001E000 BOTH */
    movl    $0x0001E003, 0x00012078   /* repair page 0x1E */
    invlpg  0x1E000
    jmp     do_exit

    /* ============================ exit ===================================== */
    .align 16
    .global do_exit
do_exit:
    movl    $0x00015000, %esp
    movl    0x00002000, %edi          /* P1: (cr2 & ~0xFFF) | err = 0x00007003 */
    /* esi = (p2 save-stands << 24) | (P2 cr2 & 0xFFFF) */
    xorl    %esi, %esi
    cmpl    $p2_done, 0x00002008   /* the saved outgoing EIP is the RESUME address */
    jne     1f
    movl    $0x01000000, %esi
1:  movl    0x0000200C, %eax
    andl    $0x0000FFFF, %eax
    orl     %eax, %esi
    /* ebp = (p3 half << 16) | p4 half; a case half-word is
     * (espok<<15) | (vector<<8) | errcode. */
    movl    0x00002010, %eax
    shll    $15, %eax
    movl    %eax, %ebp
    movl    (SLOTS+2*CNT_SLOT+0), %eax
    shll    $8, %eax
    orl     %eax, %ebp
    orl     (SLOTS+2*CNT_SLOT+4), %ebp
    shll    $16, %ebp
    movl    0x00002020, %eax
    shll    $15, %eax
    orl     %eax, %ebp
    movl    (SLOTS+3*CNT_SLOT+0), %eax
    shll    $8, %eax
    orl     %eax, %ebp
    orl     (SLOTS+3*CNT_SLOT+4), %ebp
    /* ebx = (p4b half << 16) | p4c half */
    movl    0x00002050, %eax
    shll    $15, %eax
    movl    %eax, %ebx
    movl    (SLOTS+6*CNT_SLOT+0), %eax
    shll    $8, %eax
    orl     %eax, %ebx
    orl     (SLOTS+6*CNT_SLOT+4), %ebx
    shll    $16, %ebx
    movl    0x00002054, %eax
    shll    $15, %eax
    orl     %eax, %ebx
    movl    (SLOTS+7*CNT_SLOT+0), %eax
    shll    $8, %eax
    orl     %eax, %ebx
    orl     (SLOTS+7*CNT_SLOT+4), %ebx
    /* ecx = (p4d half << 16) | p4e half */
    movl    0x00002058, %eax
    shll    $15, %eax
    movl    %eax, %ecx
    movl    (SLOTS+8*CNT_SLOT+0), %eax
    shll    $8, %eax
    orl     %eax, %ecx
    orl     (SLOTS+8*CNT_SLOT+4), %ecx
    shll    $16, %ecx
    movl    0x0000205C, %eax
    shll    $15, %eax
    orl     %eax, %ecx
    movl    (SLOTS+9*CNT_SLOT+0), %eax
    shll    $8, %eax
    orl     %eax, %ecx
    orl     (SLOTS+9*CNT_SLOT+4), %ecx
    /* edx = (busy6 << 26) | (0x0E3 << 16) | 0x00F4; busy6 bits are the six
     * P5a/P5b/P5c busy bytes' BUSY bit (acc == 0x8B), in the order
     * p5a_run, p5a_inc, p5b_inc, p5b_run, p5c_inc, p5c_run. */
    xorl    %edx, %edx
    cmpl    $0x8B, 0x00002030
    jne     2f
    orl     $0x00000020, %edx
2:  cmpl    $0x8B, 0x00002034
    jne     3f
    orl     $0x00000010, %edx
3:  cmpl    $0x8B, 0x0000203C
    jne     4f
    orl     $0x00000008, %edx
4:  cmpl    $0x8B, 0x00002040
    jne     5f
    orl     $0x00000004, %edx
5:  cmpl    $0x8B, 0x00002064
    jne     6f
    orl     $0x00000002, %edx
6:  cmpl    $0x8B, 0x00002060
    jne     7f
    orl     $0x00000001, %edx
7:  shll    $26, %edx
    orl     $0x000E300F4, %edx
    /* eax = (p5c CR2 >> 4 << 8) | 0x42 (the debug-exit port needs AL = 0x42) */
    movl    0x00002068, %eax
    shrl    $4, %eax
    shll    $8, %eax
    orl     $0x42, %eax

    outb    %al, %dx
9:  jmp     9b

    /* ================= task_trap (completed-switch poison) =================
     * Reached only if an INJECTED switch COMPLETES (none should): the whole
     * point is the rejected/partial path. Mark it and exit -- the final
     * witnesses then differ from every expectation. */
    .align 16
    .global task_trap
task_trap:
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    $0xBAD5017C, 0x00002004
    jmp     do_exit

    /* ============================== handlers ===============================
     * All faults are same-privilege CPL0 deliveries: [esp]=err [+4]=EIP
     * [+8]=CS [+12]=EFLAGS; ESP at the fault = handler esp + 16. Record the
     * staged slot, redirect the saved EIP to the resume point, pop the error
     * code, IRET. CR2 is recorded unconditionally (meaningful for #PF only). */
    .align 16
    .global ts_entry
ts_entry:
    movl    $10, %eax
    jmp     fcommon
    .align 16
    .global np_entry
np_entry:
    movl    $11, %eax
    jmp     fcommon
    .align 16
    .global gp_entry
gp_entry:
    movl    $13, %eax
    jmp     fcommon
    .align 16
    .global pf_entry
pf_entry:
    movl    $14, %eax
fcommon:
    movl    %eax, %esi                 /* save the vector */
    /* Detect WHERE the delivery's frame actually is. The pinned emulator's
     * post-commit switch faults are delivered through the just-committed SS
     * hidden cache, which is only selector-loaded at that point (flags=0),
     * so its stack-mask is 16-bit and the frame sits at (esp & 0xFFFF), not
     * at esp; a delivery through a fully-loaded SS sits at esp. Probe with a
     * scratch push (below every frame), compare where it landed, then scrub
     * both candidate dwords so a later case cannot see the leftover. */
    movl    %esp, %eax
    notl    %eax                       /* unique-ish per stack */
    pushl   %eax
    movl    %esp, %ecx
    andl    $0x0000FFFF, %ecx
    cmpl    %eax, (%ecx)               /* did the push land at the masked alias? */
    movl    $0, (%esp)
    movl    $0, (%ecx)
    popl    %eax
    je      .Lfcm_masked
    movl    %esp, %ecx                 /* no: the frame is at esp */
    jmp     .Lfcm_have
.Lfcm_masked:
    movl    %esp, %ecx                 /* yes: the frame is at (esp & 0xFFFF) */
    andl    $0x0000FFFF, %ecx          /* (recomputed from the RESTORED esp) */
.Lfcm_have:
    /* ecx = the frame's base address (err at +0, eip at +4) */
    movl    CUR_SLOT, %ebx
    cmpl    $0, (%ebx)
    jne     3f                         /* a recovery re-delivery: keep the FIRST */
    movl    %esi, (%ebx)               /* slot.vec (first delivery only) */
    movl    0(%ecx), %eax
    movl    %eax, 4(%ebx)              /* slot.err */
    leal    16(%esp), %eax
    movl    %eax, 8(%ebx)              /* slot.esp = ESP at the fault */
    movl    %cr2, %eax
    movl    %eax, 12(%ebx)             /* slot.cr2 */
    movl    4(%ecx), %eax
    movl    %eax, 16(%ebx)             /* slot.saved_eip */
3:  movl    RESUME_ADR, %eax
    movl    %eax, 4(%ecx)              /* saved EIP <- staged resume address */
    addl    $4, %esp                   /* drop the error code */
    iretl

    /* ---- IDT gate builder (EBX = handler offset, EDI = gate slot) -------- */
set_gate0:
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax          /* selector 0x08 */
    movl    %eax, (%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl    $0x00008E00, %eax           /* P, DPL0, 32-bit interrupt gate */
    movl    %eax, 4(%edi)
    ret

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
