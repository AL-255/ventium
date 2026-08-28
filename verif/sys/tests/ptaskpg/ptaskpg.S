/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug3 C-02 — a PAGED hardware task switch with NON-IDENTITY mappings,
 * differing outgoing/incoming LDTs, and TI=1 incoming selectors.
 *
 * The defect (three cur_lin mirrors stale under paging, all invisible with
 * paging OFF):
 *   (a) S_TSW_SEG resolved the INCOMING task's TI=1 segment descriptors through
 *       the live OUTGOING ldt_base instead of the staged incoming
 *       tsw_st_ldt_base, and bounds-checked the incoming selectors against the
 *       outgoing ldt_limit;
 *   (b) S_TSW_BUSY's cur_lin mirror had the two beats SWAPPED (beat0=outgoing
 *       available, beat1=incoming busy) while the bus arm writes incoming-busy
 *       first -- under non-identity paging the busy/available bytes go to the
 *       opposite descriptors' physical pages;
 *   (c) (the outer-RETF half -- pretfoutpg covers that.)
 *
 * With paging OFF every one of these is invisible: linear == physical and both
 * address generators name the same byte. This test therefore puts EVERY object
 * the switch touches on a physical frame that differs from its linear address,
 * and several objects STRADDLE page boundaries (each individual access still
 * lands within one page):
 *
 *   linear (PD[1]/PT1, the 4 MiB window)        physical         object
 *   0x400000  GDT page 1 (GDT base 0x400FE0) -> 0x800000         GDT entries 0-3
 *   0x401000  GDT page 2                     -> 0x810000         GDT entries 4-7:
 *                                                              TSS1/TSS2/LDT1/LDT2
 *                                                              descriptors (the busy
 *                                                              bytes live HERE)
 *   0x402000  TSS1                           -> 0x801000         outgoing-save target
 *   0x403000  TSS2 page 1 (TSS2 base 0x403FF0)-> 0x802000        back-link word only
 *   0x404000  TSS2 page 2                    -> 0x811000         the bulk of the
 *                                                              incoming state image
 *   0x405000  LDT1 (OUTGOING task's LDT)     -> 0x803000         limit 0x17; entry 1
 *                                                              is a NON-CODE trap
 *   0x406000  LDT2 (INCOMING task's LDT)     -> 0x804000         limit 0x1F; code
 *                                                              base 0xF0000, SS-data
 *                                                              base 0x407000, flat data
 *   0x407000  task2 stack page 1             -> 0x805000         LDT2 SS base = 0x407000
 *   0x408000  task2 stack page 2             -> 0x806000         sentinel @ 0x408FF0
 *   0x409000  markers (+ the post-paging GDTR pseudo-descriptor) -> 0x807000
 *   0x40A000  task1 stack                    -> 0x808000
 *
 * The GDT base 0x400FE0 straddles pages 0x400/0x401 so the TSS/LDT descriptors
 * (indices 4-7) sit on GDT page 2 (phys 0x810xxx) -- the busy-byte writes must
 * translate 0x401005 / 0x40100D to 0x810005 / 0x81000D, not to anything else.
 * TSS2 base 0x403FF0 straddles pages 0x403/0x404 so the back-link word is on
 * phys 0x802FF0 while the whole state image is on phys 0x8110xx.
 *
 * The OUTGOING task LLDTs LDT1 (base 0x405000, limit 0x17) so the live
 * ldt_base/ldt_limit DIFFER from the incoming LDT2 (base 0x406000, limit 0x1F)
 * in BOTH properties. The incoming TSS2 image uses TI=1 selectors:
 *   CS = 0x0C (LDT2 idx1: code32 base 0x000F0000 limit 0xFFFF -- task2's EIP is
 *       the OFFSET task2-0xF0000),
 *   SS = 0x14 (LDT2 idx2: data32 base 0x00407000 limit 0x1FFF -- task2's stack
 *       window; ESP = 0x1FF0 -> linear 0x408FF0),
 *   DS/ES/FS/GS = 0x1C (LDT2 idx3: data32 flat).
 * If the switch resolves these through the OUTGOING LDT1 instead (the defect),
 * CS reads LDT1 entry 1 -- a deliberately NON-CODE descriptor (base 0xDEAD0000)
 * -- and the bounds check rejects 0x1C against LDT1's smaller limit 0x17:
 * either way the buggy build faults or reads the wrong physical page, and the
 * differential diverges. With the fix, LDT2's descriptors resolve and task2
 * runs on the incoming task's own segments.
 *
 * WITNESSES (marker page, pulled into GPRs at the exit so the golden-vs-RTL
 * differential compares them; QEMU is the oracle):
 *   0x409020/24/28  incoming reload: EAX=0xAAAAAAAA, EBX=0xBBBBBBBB, ESP=0x1FF0
 *   0x40902C  0x5EED0001 -- task2 read it via SS:(%esp): the sentinel was
 *             pre-seeded at PHYS 0x806FF0 = linear 0x408FF0 = LDT2-SS-base
 *             0x407000 + ESP 0x1FF0. Only the CORRECT incoming SS descriptor
 *             base makes this read hit the sentinel.
 *   0x409030  SLDT == 0x0038 -- LDTR switched to the incoming LDT2 selector.
 *   0x409034  STR == 0x0028.
 *   0x409038  (TSS1 access<<8)|TSS2 access == 0x898B read through PAGING at
 *             linear 0x401005/0x40100D: the busy bytes toggled on the correct
 *             PHYSICAL page (0x810005/0x81000D) -- beat-order defect (b) swaps
 *             them (0x8B89) or CHECK 5 fires on the stale mirror.
 *   0x409040  TSS1 saved EIP (linear 0x402020) -- nonzero, the outgoing save
 *             landed on phys 0x801020.
 *   0x409044  TSS1 saved EAX == 0x1A1A1A1A (the live EAX at the jmp).
 *
 * NEGATIVE CONTROL (REQUIRED, see manifest.json): the HEAD TB (no fix) resolves
 * the incoming CS through the OUTGOING LDT1 (a non-code trap descriptor) and/or
 * bounds it against the wrong limit -> #TS before task2 runs, and/or the
 * PAGING/C-04 CHECK-5 $error fires on the stale mirror. Measured: divergence
 * during S_TSW_SEG, long before any witness.
 *
 * Boots F000:FFF0; real->protected via a small boot GDT (the REAL GDT is
 * LGDT'd only after paging, with its LINEAR base 0x400FE0). GNU-as; no nasm.
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

    /* --- boot GDT (3 entries) at linear 0x0500: ONLY for the PM transition ---
     * The real GDT is built at its PHYSICAL home pre-paging and LGDT'd
     * post-paging with the LINEAR base 0x400FE0 (descriptor bases are linear). */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 flat */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 flat */
    movl    $0x00CF9200, 20(%ebx)
    movw    $0x0017, 0x0480
    movl    $0x00000500, 0x0482
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
    movl    $0x00090000, %esp           /* pre-paging scratch stack (phys) */

    /* ==================== build the page tables (phys writes) ============== */
    /* PT0 @ phys 0x12000: identity-map the CODE window [0xF0000,0x100000). */
    movl    $0x000123C0, %edi           /* &PT0[0xF0] */
    movl    $0x000F0003, %eax
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b

    /* PT1 @ phys 0x13000: the NON-IDENTITY window for linear [4 MiB, 8 MiB).
     * entry[i] = linear 0x400000+i*0x1000 -> the physical frame in the plan. */
    movl    $0x00013000, %edi
    movl    $0x00800003, 0(%edi)        /* [0] 0x400000 -> 0x800000 GDT page 1 */
    movl    $0x00810003, 4(%edi)        /* [1] 0x401000 -> 0x810000 GDT page 2 */
    movl    $0x00801003, 8(%edi)        /* [2] 0x402000 -> 0x801000 TSS1 */
    movl    $0x00802003, 12(%edi)       /* [3] 0x403000 -> 0x802000 TSS2 page 1 */
    movl    $0x00811003, 16(%edi)       /* [4] 0x404000 -> 0x811000 TSS2 page 2 */
    movl    $0x00803003, 20(%edi)       /* [5] 0x405000 -> 0x803000 LDT1 */
    movl    $0x00804003, 24(%edi)       /* [6] 0x406000 -> 0x804000 LDT2 */
    movl    $0x00805003, 28(%edi)       /* [7] 0x407000 -> 0x805000 task2 stk 1 */
    movl    $0x00806003, 32(%edi)       /* [8] 0x408000 -> 0x806000 task2 stk 2 */
    movl    $0x00807003, 36(%edi)       /* [9] 0x409000 -> 0x807000 markers */
    movl    $0x00808003, 40(%edi)       /* [A] 0x40A000 -> 0x808000 task1 stack */

    /* PD @ phys 0x11000 */
    movl    $0x00012003, 0x00011000     /* PD[0] -> PT0 (identity low) */
    movl    $0x00013003, 0x00011004     /* PD[1] -> PT1 (non-identity @4 MiB) */

    /* ==================== the REAL GDT, straddling two phys frames ==========
     * 8 entries at linear 0x400FE0 = phys 0x800FE0 (entries 0-3) + phys
     * 0x810000 (entries 4-7). The busy bytes of the TSS descriptors are on
     * GDT page 2 (phys 0x810005 / 0x81000D). */
    movl    $0x00000000, 0x00800FE0     /* idx0 null */
    movl    $0x00000000, 0x00800FE4
    movl    $0x0000FFFF, 0x00800FE8     /* idx1 0x08 code0 flat */
    movl    $0x00CF9A00, 0x00800FEC
    movl    $0x0000FFFF, 0x00800FF0     /* idx2 0x10 data0 flat */
    movl    $0x00CF9200, 0x00800FF4
    movl    $0x0000FFFF, 0x00800FF8     /* idx3 0x18 filler data32 */
    movl    $0x00CF9200, 0x00800FFC
    /* idx4 0x20 TSS1: base LINEAR 0x402000, limit 0x67, access 0x89 */
    movl    $0x20000067, 0x00810000     /* limit=0x0067, base[15:0]=0x2000 */
    movl    $0x00008940, 0x00810004     /* base[23:16]=0x40, acc=0x89 */
    /* idx5 0x28 TSS2: base LINEAR 0x403FF0, limit 0x77 (straddles 0x403/0x404) */
    movl    $0x3FF00077, 0x00810008     /* limit=0x0077, base[15:0]=0x3FF0 */
    movl    $0x00008940, 0x0081000C     /* base[23:16]=0x40, acc=0x89 */
    /* idx6 0x30 LDT1 (OUTGOING): base LINEAR 0x405000, limit 0x17, access 0x82 */
    movl    $0x50000017, 0x00810010
    movl    $0x00008240, 0x00810014
    /* idx7 0x38 LDT2 (INCOMING): base LINEAR 0x406000, limit 0x1F, access 0x82 */
    movl    $0x6000001F, 0x00810018
    movl    $0x00008240, 0x0081001C

    /* post-paging GDTR pseudo-descriptor at PHYS 0x807000 (= linear 0x409000):
     * limit 0x3F (8 entries), base LINEAR 0x400FE0. */
    movw    $0x003F, 0x00807000
    movl    $0x00400FE0, 0x00807002

    /* ==================== TSS1 (outgoing-save target) @ phys 0x801000 ======= */
    movl    $0x00801000, %edi
    xorl    %eax, %eax
    movl    $52, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movw    $0x0068, 0x00801066         /* I/O map base (empty) */

    /* ==================== TSS2 (incoming image), straddling =================
     * base linear 0x403FF0 = phys 0x802FF0 (bytes 0xFF0..0xFFF: offsets 0x00-
     * 0x0F) + phys 0x811000 (offsets 0x10..0x77). Zero both, then fill.      */
    movl    $0x00802FF0, %edi
    xorl    %eax, %eax
    movl    $4, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00811000, %edi
    movl    $30, %ecx                   /* 0x811000..0x811077 */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* incoming state image (offset >= 0x10 -> phys 0x811000 + (off - 0x10),
     * because TSS2 base 0x403FF0 puts offsets 0x00-0x0F on phys 0x802FF0 and
     * offset 0x10 at linear 0x404000 = phys 0x811000):
     *   CR3=PD base (paging STAYS ON across the switch), EIP=task2 OFFSET in
     *   the LDT2 code segment (base 0xF0000), EFLAGS=0x2, marker GPRs,
     *   ESP=0x1FF0 (offset in the LDT2 SS window, base 0x407000),
     *   TI=1 selectors CS=0x0C SS=0x14 DS/ES/FS/GS=0x1C, LDTR=0x38 (LDT2).   */
    movl    $0x00011000, 0x0081100C     /* CR3 (offset 0x1C) */
    movl    $(task2 - 0xF0000), %eax
    movl    %eax,        0x00811010     /* EIP (offset 0x20) = task2 - CSbase */
    movl    $0x00000002, 0x00811014     /* EFLAGS */
    movl    $0xAAAAAAAA, 0x00811018     /* EAX marker */
    movl    $0xBBBBBBBB, 0x00811024     /* EBX marker */
    movl    $0x00001FF0, 0x00811028     /* ESP (offset in SS window 0x407000) */
    movl    $0x0000001C, 0x00811038     /* ES = 0x1C (TI=1, LDT2 idx3 flat) */
    movl    $0x0000000C, 0x0081103C     /* CS = 0x0C (TI=1, LDT2 idx1 code) */
    movl    $0x00000014, 0x00811040     /* SS = 0x14 (TI=1, LDT2 idx2 stack) */
    movl    $0x0000001C, 0x00811044     /* DS = 0x1C */
    movl    $0x0000001C, 0x00811048     /* FS = 0x1C */
    movl    $0x0000001C, 0x0081104C     /* GS = 0x1C */
    movl    $0x00000038, 0x00811050     /* LDTR = 0x38 (LDT2) */
    movw    $0x0078,     0x00811056     /* I/O map base = limit+1 (empty) */
    /* back-link word (offset 0, phys 0x802FF0) stays 0 -- a JMP writes none. */

    /* ==================== the two LDTs ======================================
     * LDT1 (OUTGOING) @ phys 0x803000, limit 0x17. Entry 1 is a TRAP: a
     * present NON-CODE data descriptor with a poison base 0xDEAD0000. If the
     * switch resolves the incoming CS through the OUTGOING LDT (the C-02
     * defect), it reads THIS descriptor, fails the code-segment check, and
     * the run diverges here. */
    movl    $0x00000000, 0x00803000     /* LDT1 idx0 null */
    movl    $0x00000000, 0x00803004
    movl    $0x00000FFF, 0x00803008     /* idx1: data32 base 0xDEAD0000 (NON-CODE) */
    movl    $0xDE4092AD, 0x0080300C
    movl    $0x0000FFFF, 0x00803010     /* idx2: filler data32 flat */
    movl    $0x00CF9200, 0x00803014

    /* LDT2 (INCOMING) @ phys 0x804000, limit 0x1F. */
    movl    $0x00000000, 0x00804000     /* idx0 null */
    movl    $0x00000000, 0x00804004
    /* idx1 0x0C: code32 base 0x000F0000 limit 0xFFFF (byte gran, D=1), acc 0x9A */
    movl    $0x0000FFFF, 0x00804008
    movl    $0x00409A0F, 0x0080400C
    /* idx2 0x14: data32 base 0x00407000 limit 0x1FFF (B=1), acc 0x92 */
    movl    $0x70001FFF, 0x00804010
    movl    $0x00409240, 0x00804014
    /* idx3 0x1C: data32 flat base 0 limit 0xFFFFF G=1, acc 0x92 */
    movl    $0x0000FFFF, 0x00804018
    movl    $0x00CF9200, 0x0080401C

    /* sentinel at PHYS 0x806FF0 = linear 0x408FF0 = LDT2-SS-base 0x407000 +
     * ESP 0x1FF0. task2 reads it via SS:(%esp): ONLY the correct incoming SS
     * descriptor base lands on it. */
    movl    $0x5EED0001, 0x00806FF0

    /* ==================== enable paging ==================================== */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0                  /* CR0.PG=1: paging ON */

    /* post-paging: task1 runs on its non-identity stack */
    movl    $0x0040AFF0, %esp           /* linear 0x40AFF0 -> phys 0x808FF0 */

    /* LGDT the REAL GDT (pseudo-descriptor at LINEAR 0x409000 -> phys 0x807000;
     * GDTR base is the LINEAR 0x400FE0, straddling phys 0x800FE0/0x810000). */
    lgdt    0x00409000

    /* LLDT LDT1 (0x30): the OUTGOING task's LDT -- base 0x405000 / limit 0x17,
     * deliberately DIFFERENT in both properties from the incoming LDT2
     * (0x406000 / 0x1F). The defect resolves the incoming TI=1 selectors
     * through THESE live values. */
    movw    $0x0030, %ax
    lldt    %ax

    /* LTR TSS1 (0x20): descriptor read at linear 0x401000 (-> phys 0x810000);
     * the busy-byte write lands at linear 0x401005 (-> phys 0x810005). */
    movw    $0x0020, %ax
    ltr     %ax

    /* clear the visible GPRs so the incoming reload is stark */
    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %edi, %edi

    movl    $0x11111111, 0x00409010     /* "task1 reached the switch point" */
    movl    $0x1A1A1A1A, %eax           /* live EAX the outgoing save records */

    /* ===================== THE PAGED HARDWARE TASK SWITCH ================== *
     * Far JMP to TSS2 (0x28). Every object the switch touches is non-identity
     * mapped: outgoing save -> linear 0x402xxx (phys 0x801xxx); incoming read
     * -> linear 0x403FF0/0x404xxx (phys 0x802FF0/0x811xxx); incoming LDT desc
     * -> linear 0x401018 (phys 0x810018); incoming seg descs -> LDT2 linear
     * 0x406xxx (phys 0x804xxx) [the defect reads LDT1 phys 0x803xxx]; busy
     * bytes -> linear 0x401005/0x40100D (phys 0x810005/0x81000D).           */
    ljmp    $0x28, $0                   /* TASK SWITCH to TSS2 (offset ignored) */

task1_resumed:
    movl    $0x99999999, 0x00409014     /* (only if a switch-back ever happens) */
hang1:
    hlt
    jmp     hang1

    /* ============================== task2 =============================== *
     * Entered with CS=0x0C (LDT2 code, base 0xF0000) so EIP is the offset
     * task2-0xF0000; SS=0x14 (LDT2 stack, base 0x407000), ESP=0x1FF0;
     * DS/ES/FS/GS=0x1C (LDT2 flat). Everything below is only reachable if the
     * incoming descriptors resolved through the INCOMING LDT2.                */
    .align 16
    .global task2
task2:
    movl    %eax, 0x00409020            /* 0xAAAAAAAA (reload proof) */
    movl    %ebx, 0x00409024            /* 0xBBBBBBBB */
    movl    %esp, 0x00409028            /* 0x00001FF0 */
    movl    $0x22222222, 0x00409048     /* "task2 is running" */

    /* SS-base proof: read via SS:(%esp) = linear 0x408FF0 (phys 0x806FF0).
     * esp-based addressing defaults to SS; only the correct incoming SS
     * descriptor base (0x407000) lands on the seeded sentinel. */
    movl    (%esp), %edx
    movl    %edx, 0x0040902C            /* expect 0x5EED0001 */

    /* LDTR/TR proofs */
    sldt    %ax
    movzwl  %ax, %eax
    movl    %eax, 0x00409030            /* expect 0x0038 (incoming LDT2) */
    str     %ax
    movzwl  %ax, %eax
    movl    %eax, 0x00409034            /* expect 0x0028 */

    /* BUSY-bit toggle proof THROUGH PAGING: TSS1 access @ linear 0x401005
     * (expect 0x89 available after a JMP), TSS2 access @ linear 0x40100D
     * (expect 0x8B busy). Both bytes are on GDT page 2, phys 0x810005/0x81000D
     * -- the beat-order defect (C-02(b)) writes them to the OPPOSITE physical
     * addresses. */
    movzbl  0x00401005, %eax
    movl    %eax, 0x00409038
    movzbl  0x0040100D, %ebx
    movl    %ebx, 0x0040903C
    shll    $8, %eax
    orl     %ebx, %eax                  /* expect 0x0000898B */
    movl    %eax, %edi                  /* edi witness = 0x898B */

    /* outgoing SAVE proof: TSS1 saved EIP/EAX at linear 0x402020/0x402028
     * (phys 0x801020/0x801028). */
    movl    0x00402020, %edx            /* nonzero resume EIP */
    movl    %edx, 0x00409040
    movl    0x00402028, %esi            /* expect 0x1A1A1A1A */
    movl    %esi, 0x00409044

    movl    $0x22222222, %ecx           /* task2 sentinel */

    /* isa-debug-exit: out 0xf4, 0x42 -> qemu status (0x42<<1)|1 = 133. */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
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
