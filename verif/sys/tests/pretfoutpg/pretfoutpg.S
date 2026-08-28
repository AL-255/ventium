/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug3 C-02 (outer-RETF half) + H-02 — a PAGED outer-level far RETF
 * whose outer ESP/SS pops land on a DIFFERENT physical page than the linear
 * page, in BOTH operand sizes.
 *
 * The defects:
 *   C-02(a): the bus arm uses retf_out/retf_ob to read the outer ESP at +2w
 *       and the outer SS at +3w, but the cur_lin mirror had only the 2-beat
 *       inner form (IP/CS). With paging enabled, beats 2 and 3 translate the
 *       WRONG linear address -- invisible with paging off (linear==physical).
 *   H-02: the 16-bit outer form read the popped outer SP as a DWORD: the
 *       frame there is a word SP followed immediately by a word SS, so the
 *       dword read carried SS into the upper half and installed
 *       {SS,SP} = 0x0023_4FF0 as ESP. The fix zero-extends the SP word.
 *
 * To make beats 2/3 observably different from beats 0/1, each frame STRADDLES
 * a page boundary: IP/CS sit on one linear page, the outer ESP/SS on the next
 * linear page, and the two pages map to DISTANT physical frames. A stale
 * 2-beat mirror therefore either faults (wrong linear unmapped) or reads the
 * wrong physical page; the differential diverges either way.
 *
 * Two cases in one image (both originate at CPL0; the ring-3 leg of case 1
 * re-enters CPL0 with an int 0x80 through the IDT/TSS):
 *
 *   case 1 (32-bit outer RETF): frame at linear 0x400FF8 --
 *       IP@0x400FF8 CS@0x400FFC   (page 0x400 -> phys 0x800FF8/0x800FFC)
 *       outer ESP@0x401000 SS@0x401004 (page 0x401 -> phys 0x810000/0x810004)
 *       pops to ring 3 A: SS must be 0x23, ESP must be 0x402FF0 (page 0x402
 *       -> phys 0x801FF0). Witness ebp=0x0C06_00<ss>, edx=esp.
 *   case 2 (16-bit outer RETF, `lretw`): word frame at linear 0x403FF0 on a
 *       NON-IDENTITY page (page 0x403 -> phys 0x802FF0): word IP@+0, CS@+2,
 *       SP@+4, SS@+6. (No straddle here: this core's pop beats are
 *       dword-granular, so a straddling 16-bit frame trips the documented
 *       PAGING/C-04 UNSPLIT assertion -- a known unimplemented producer.)
 *       pops to ring 3 B at EIP 0x3000 (16-bit IP -> a low identity page):
 *       SS must be 0x23 and ESP must be 0x00004FF0 (the SP word ZERO-EXTENDED;
 *       H-02's dword read gave 0x00234FF0). Witness ebp=0x1606_00<ss>, esi=esp.
 *
 * Page map (PD[1]/PT1, the non-identity 4 MiB window; PT0 identity):
 *   PT0: [0,0x6000) 6 pages (GDT 0x500 / IDT 0x1000 supervisor; markers 0x2000,
 *        r3b code 0x3000, ring3-B stack 0x4000 USER) + [0xF0000,0x100000)
 *        16 pages USER (ring-3 A executes from the image window)
 *   PT1: [0] 0x400000->0x800000 CPL0 stack pg1 (case1 frame IP/CS)
 *        [1] 0x401000->0x810000 CPL0 stack pg2 (case1 outer ESP/SS)
 *        [2] 0x402000->0x801000 ring3-A stack (USER)
 *        [3] 0x403000->0x802000 TSS0 stack pg1 (int frame + case2 word frame)
 *        [4] 0x404000->0x811000 TSS0 stack pg2 (spare)
 *        [5] 0x405000->0x803000 TSS (SS0=0x10, ESP0=0x403FF0)
 *
 * WITNESSES (marker page at linear 0x2000, pulled into the GPRs at the exit
 * for the record-for-record differential; QEMU is the oracle):
 *   0x2000  0x0C060023 -- case1 ring-3 SS (the frame's outer SS was popped)
 *   0x2004  0x00402FF0 -- case1 ring-3 ESP (the outer ESP beat landed on the
 *           correct PHYSICAL page, phys 0x810000)
 *   0x2008  0x80808080 -- the int 0x80 handler ran (ring3 A -> CPL0 re-entry)
 *   0x200C  0x16060023 -- case2 ring-3 SS
 *   0x2010  0x00004FF0 -- case2 ring-3 ESP: the 16-bit outer SP word
 *           ZERO-EXTENDED (H-02); the dword-read defect gives 0x00234FF0
 *
 * NEGATIVE CONTROL (REQUIRED, see manifest.json): the HEAD TB translates
 * beats 2/3 with the stale 2-beat cur_lin form AND reads the 16-bit outer SP
 * as a dword: measured divergence at the case-1 RETF (wrong physical page /
 * PAGING-CHECK-5 $error), long before any witness.
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

    /* --- GDT (6 entries) at linear 0x0500 (identity-mapped low page) ---
     * null + code0 0x08 + data0 0x10 + code3 0x18 + data3 0x20 + TSS 0x28 */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* 0x08 code32 DPL0 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* 0x10 data32 DPL0 */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* 0x18 code32 DPL3 -> 0x1B */
    movl    $0x00CFFA00, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* 0x20 data32 DPL3 -> 0x23 */
    movl    $0x00CFF200, 36(%ebx)
    /* 0x28 TSS: base LINEAR 0x405000, limit 0x67, access 0x89 */
    movl    $0x50000067, 40(%ebx)       /* limit=0x0067, base[15:0]=0x5000 */
    movl    $0x00008940, 44(%ebx)       /* base[23:16]=0x40, acc=0x89 */

    movw    $0x002F, 0x0480
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
    movl    $0x00009000, %esp           /* pre-paging scratch stack (phys) */

    /* zero the marker page area 0x2000..0x2020 */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $8, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000: gate 0x80 -> int_handler, INTERRUPT gate DPL 3 ----
     * (0x1000 + 0x80*8 = 0x1400; access 0xEE = P|DPL3|int32)              */
    movl    $int_handler, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1400
    movl    $int_handler, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ee00, %eax
    movl    %eax, 0x1404
    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- copy the ring-3 B routine to PHYS 0x3000 (identity linear 0x3000).
     * The 16-bit outer RETF supplies a WORD IP, so the target EIP must be
     * below 0x10000; the image lives at 0xFxxxx, hence the copy. ---------- */
    movl    $r3b_src, %esi
    movl    $0x00003000, %edi
    movl    $(r3b_src_end - r3b_src + 3)/4, %ecx   /* whole r3b routine */
1:  movsl
    loop    1b

    /* ==================== build the page tables (phys writes) ============== */
    /* PT0 @ phys 0x12000:
     *   [0..5] identity [0,0x6000): pages 0-1 SUPERVISOR (GDT/IDT), pages
     *          2-4 USER (markers/r3b code/ring3-B stack), page 5 supervisor
     *   [0xF0..0xFF] identity [0xF0000,0x100000) USER (ring-3 A runs there) */
    movl    $0x00012000, %edi
    movl    $0x00000003, 0(%edi)        /* page 0: GDT, supervisor */
    movl    $0x00001003, 4(%edi)        /* page 1: IDT, supervisor */
    movl    $0x00002007, 8(%edi)        /* page 2: markers, USER */
    movl    $0x00003007, 12(%edi)       /* page 3: r3b code, USER */
    movl    $0x00004007, 16(%edi)       /* page 4: ring3-B stack, USER */
    movl    $0x00005003, 20(%edi)       /* page 5: supervisor scratch */
    movl    $0x000123C0, %edi           /* &PT0[0xF0] */
    movl    $0x000F0007, %eax           /* identity, P|RW|US */
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b

    /* PT1 @ phys 0x13000: the NON-IDENTITY window (see the plan above) */
    movl    $0x00013000, %edi
    movl    $0x00800003, 0(%edi)        /* [0] 0x400000 -> 0x800000 CPL0 stk 1 */
    movl    $0x00810003, 4(%edi)        /* [1] 0x401000 -> 0x810000 CPL0 stk 2 */
    movl    $0x00801007, 8(%edi)        /* [2] 0x402000 -> 0x801000 r3-A stk US */
    movl    $0x00802003, 12(%edi)       /* [3] 0x403000 -> 0x802000 TSS0 stk 1 */
    movl    $0x00811003, 16(%edi)       /* [4] 0x404000 -> 0x811000 TSS0 stk 2 */
    movl    $0x00803003, 20(%edi)       /* [5] 0x405000 -> 0x803000 TSS */

    /* PD @ phys 0x11000 -- US=1 on BOTH entries so the USER PTEs below are
     * actually user-accessible (effective US = PD.US & PT.US); the PTEs still
     * keep the GDT/IDT/stack pages supervisor-only. */
    movl    $0x00012007, 0x00011000     /* PD[0] -> PT0 */
    movl    $0x00013007, 0x00011004     /* PD[1] -> PT1 */

    /* ---- TSS at PHYS 0x803000 (= linear 0x405000): SS0=0x10, ESP0=0x403FF0 */
    movl    $0x00803000, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $0x00403FF0, 0x00803004     /* ESP0 (linear; page 0x403 -> 0x802FF0) */
    movl    $0x00000010, 0x00803008     /* SS0 */
    movw    $0x0068,     0x00803066

    /* ==================== enable paging ==================================== */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0                  /* CR0.PG=1 */

    movl    $0x00401008, %esp           /* CPL0 stack (linear; phys 0x810008) */

    /* IOPL = 3 so both ring-3 legs may drive port 0xF4. */
    pushfl
    orl     $0x00003000, (%esp)
    popfl

    movw    $0x0028, %ax
    ltr     %ax

    /* ==================== case 1: 32-bit OUTER RETF, straddling frame ======
     * ESP is 0x401008 after these 4 pushes; the lret pops IP@0x400FF8,
     * CS@0x400FFC (page 0x400, phys 0x800FF8/0x800FFC), then -- because the
     * popped CS.RPL(3) > CPL(0) -- the OUTER ESP@0x401000 and OUTER
     * SS@0x401004 (page 0x401, phys 0x810000/0x810004). C-02(a)'s stale
     * 2-beat mirror translates beats 2/3 from the wrong linear.           */
    pushl   $0x00000023                 /* outer SS  = ring-3 data, RPL 3 */
    pushl   $0x00402FF0                 /* outer ESP = ring-3 A stack (page 0x402) */
    pushl   $0x0000001B                 /* CS  = ring-3 code, RPL 3 */
    pushl   $r3a_entry                  /* EIP */
    lret

    /* Reached only if the RETF did not transfer at all. */
    movl    $0xBADBAD00, 0x0000201C
9:  jmp     9b

    /* ============================ ring 3 A (case 1) ======================== */
    .global r3a_entry
r3a_entry:
    /* CPL 3. The outer RETF NULLED DS/ES/FS/GS (DPL 0 < new CPL 3 -- both
     * oracles do this; the golden shows ds=0 in ring 3). Reload DS before ANY
     * data access: a null-DS store is architecturally #GP-worthy and the
     * VEN_SEG_ENFORCE build (make seg) rightly faults on it.
     * THE WITNESS IS THE STACK: SS must be 0x23 (the frame's outer SS)
     * and ESP must be 0x402FF0. SS is read via memory (movw %ss,mem + movzwl)
     * rather than mov r32,sreg: QEMU zero-extends the selector into the 32-bit
     * register while this core preserves the stale upper half -- a REAL but
     * PRE-EXISTING divergence unrelated to C-02/H-02, kept out of this test so
     * the diff isolates the outer-RETF fixes (recorded in the manifest). */
    movw    $0x23, %ax
    movw    %ax, %ds
    movw    %ss, 0x00002014
    movzwl  0x00002014, %eax
    orl     $0x0C060000, %eax           /* witness = 0x0C06_00<ss>, want 0x23 */
    movl    %eax, 0x00002000
    movl    %esp, 0x00002004            /* want 0x00402FF0 */

    /* re-enter CPL0 for case 2 via int 0x80 (gate DPL 3, stack switch to
     * TSS.SS0:ESP0 = 0x10:0x403FF0) */
    int     $0x80

    /* unreachable: the handler ends in the case-2 lretw, not an iret */
    movl    $0xDEAD0B0B, 0x00002018
9:  jmp     9b

    /* ===================== int 0x80 handler (CPL0) ========================= */
    .global int_handler
int_handler:
    /* DS was nulled by the outer RETF (see r3a_entry) -- reload for stores. */
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    $0x80808080, 0x00002008     /* "int 0x80 handler ran" */

    /* ==================== case 2: 16-bit OUTER RETF ========================
     * Build the WORD frame at linear 0x403FF0 (page 0x403 -> phys 0x802FF0,
     * NON-IDENTITY): word IP@+0, word CS@+2, word SP@+4, word SS@+6. `lretw`
     * (0x66 CB) pops IP/CS then the outer word SP/SS. H-02: the SP word must
     * be ZERO-EXTENDED (0x00004FF0) -- the dword-read defect installs
     * {SS,SP} = 0x00234FF0.
     * The frame deliberately does NOT straddle a page boundary (unlike case
     * 1): this core's pop BEATS are dword-granular, so the CS beat at ESP+2
     * (and the SS beat at ESP+6) would cross the boundary and trip the
     * documented PAGING/C-04 UNSPLIT assertion -- a known unimplemented
     * producer, not the property this test grades. The non-identity page is
     * what makes C-02(a)'s stale 2-beat cur_lin mirror observable here: the
     * buggy beats 2/3 read ESP-q_w (0x403FEE, wrong LINEAR) instead of
     * ESP+2w/+3w, landing on the wrong data through the right page.        */
    movw    $0x3000, %ax                /* IP word: r3b runs at linear 0x3000 */
    movw    %ax, 0x00403FF0
    movw    $0x001B, 0x00403FF2         /* CS word = ring-3 code RPL 3 */
    movw    $0x4FF0, 0x00403FF4         /* SP word */
    movw    $0x0023, 0x00403FF6         /* SS word */
    movl    $0x00403FF0, %esp
    .byte   0x66, 0xCB                  /* lretw (16-bit operand-size RETF) */

    movl    $0xBADBAD02, 0x0000201C
9:  jmp     9b

    /* ===================== ring 3 B (case 2), runs at 0x3000 ===============
     * Copied to PHYS 0x3000 pre-paging; entered with EIP=0x3000, SS=0x23,
     * ESP=0x00004FF0 (if H-02's zero-extension is right).                  */
    .global r3b_src
r3b_src:
    movw    $0x23, %ax                  /* DS was nulled by the outer RETF */
    movw    %ax, %ds
    movw    %ss, 0x00002014
    movzwl  0x00002014, %eax            /* (see r3a: mov r32,sreg kept out) */
    orl     $0x16060000, %eax           /* witness = 0x1606_00<ss>, want 0x23 */
    movl    %eax, 0x0000200C
    movl    %esp, 0x00002010            /* want 0x00004FF0 (NOT 0x00234FF0) */

    /* pull every witness into the GPRs for the final-record compare.
     * NOTE: the exit sequence clobbers EAX (0x42) and DX (0xF4), so the
     * 32-bit witnesses use edi/ebp/ebx/esi/ecx only.                       */
    movl    0x00002000, %edi            /* case1 SS witness (0x0C060023) */
    movl    0x00002004, %ebp            /* case1 ESP witness (0x00402FF0) */
    movl    0x00002008, %ebx            /* int-handler sentinel (0x80808080) */
    movl    0x0000200C, %esi            /* case2 SS witness (0x16060023) */
    movl    0x00002010, %ecx            /* case2 ESP witness (0x00004FF0) */

    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                    /* CPL==IOPL==3 */
9:  jmp     9b
    .global r3b_src_end
r3b_src_end:

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
