/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * pdescprec — REVIEW_Aug4 A4-H05: descriptor fault PRECEDENCE for
 * combined-invalid descriptors. Differential against the QEMU golden.
 *
 * The architectural order (implemented by the pinned QEMU 8.2.2 in
 * tss_load_seg / helper_load_seg / do_interrupt_protected /
 * helper_ljmp_protected / helper_ret_protected in
 * target/i386/tcg/seg_helper.c) is: S/type/privilege checks (#GP) BEFORE
 * presence (#NP/#SS). A descriptor that is NOT-PRESENT *AND* wrong-type (or
 * privilege-failing) must therefore report #GP, not #NP. The pre-fix RTL
 * evaluated presence FIRST (seg_load_fault: `if (!desc_present) fault`;
 * seg_fault_vec: "NP iff P=0"; the IDT gate arm and the interrupt target-CS
 * arm in core_int_deliver.svh likewise), so every combined-invalid case below
 * delivered #NP where both oracles say #GP.
 *
 * THE CASES (8 combined-invalid discriminators + 8 single-invalid controls;
 * each records {cs<<16|vector} and the error code into its own marker slots;
 * the faulting instruction is resumed past by the handler):
 *
 *   Fam 1  MOV Sreg loads:
 *     1a  DS <- 0x28: P=0 SYSTEM descriptor (LDT, S=0)          -> #GP(0x28)
 *     ctl DS <- 0x30: P=0, otherwise valid data DPL0            -> #NP(0x30)
 *     1b  DS <- 0x38: P=0 data DPL=0, loaded at CPL3            -> #GP(0x38)
 *     ctl DS <- 0x40: P=0 data DPL=3, loaded at CPL3            -> #NP(0x40)
 *     1c  SS <- 0x48: P=0 CODE descriptor (not writable data)   -> #GP(0x48)
 *     ctl SS <- 0x50: P=0 writable data, DPL==CPL==RPL          -> #SS(0x50)
 *   Fam 2  direct far JMP (CPL0):
 *         ljmp -> 0x58: P=0 DATA descriptor (not code)          -> #GP(0x58)
 *     ctl ljmp -> 0x60: P=0 valid code descriptor               -> #NP(0x60)
 *   Fam 3  IDT gate:
 *         int $32 with IDT[32] = P=0 LDT descriptor (S=0,type2) -> #GP(0x102)
 *     ctl int $33 with IDT[33] = P=0 legal 32-bit int gate      -> #NP(0x10A)
 *   Fam 4  interrupt target CS:
 *         int $34: present gate -> 0x68 P=0 DATA desc           -> #GP(0x68)
 *     ctl int $35: present gate -> 0x70 P=0 valid code desc     -> #NP(0x70)
 *       The error code blames the gate's TARGET CS selector (a GDT/LDT
 *       descriptor, not the IDT entry): TI from the selector, IDT=0, EXT=0
 *       for a software INT -- sel & 0xFFFC, exactly QEMU's
 *       do_interrupt_protected form, so fam 4 is fully differential.
 *   Fam 4b interrupt target CS in the LDT (TI=1), differential:
 *         int $36: present gate -> 0x000C P=0 LDT DATA desc       -> #GP(0x000C)
 *     ctl int $37: present gate -> 0x0014 P=0 valid LDT code desc -> #NP(0x0014)
 *       Same target-CS blame form as fam 4, now with TI=1: the pushed code
 *       must PRESERVE the selector's TI bit (0x000C/0x0014, not 0x0008/0x0010),
 *       keep IDT=0 and EXT=0. In-guest asserts check the three low bits
 *       separately (fail edi = 0x94 TI / 0x95 IDT / 0x96 EXT) so a swapped-bit
 *       regression names the bit, not just the word.
 *   Fam 5  RETF (same-privilege, CPL0; ESP preserved per H-02):
 *         lret with popped CS = 0x58 (P=0 DATA)                 -> #GP(0x58)
 *     ctl lret with popped CS = 0x60 (P=0 code)                 -> #NP(0x60)
 *   Fam 7  atomic protected far-pointer load:
 *         LDS ESI,m16:32 with selector 0x30 (P=0 data)          -> #NP(0x30)
 *         ESI must remain 0xA55A1234; descriptor rejection may not expose
 *         the offset half of this two-destination instruction.
 *
 *   Fam 6 (task switch): the S_LJMP system-descriptor dispatch is a typed
 *   classifier in the pinned oracle's precedence (type/DPL before presence,
 *   a default-case #GP for outright-rejected classes; the loud halt survives
 *   only for task gate / 286 TSS / NT-return-to-non-busy, after the
 *   architecturally required faults). The combined-invalid shapes are
 *   differentially reachable and covered by pxfer's combined-invalid matrix
 *   (P=0+wrong-type and P=0+DPL for available/busy TSS, LDT, task gate, and
 *   call gate, each with a presence-only control), so this image carries no
 *   fam-6 case of its own.
 *
 * GRADING: fully differential (QEMU golden vs RTL, per-instruction register
 * compare). Every witness flows through registers twice — when the handler
 * stores it and when the exit loop verifies it against the in-image expected
 * table and XOR-folds it — so a vector or error-code divergence breaks the
 * diff at the first record that sees it. The exit also self-checks every
 * slot against the expected table (fail edi = 0x80|cases-left), the delivery
 * counters (fail edi = 0x90..0x93), then stages:
 *   edi = 0x42 (pass)            ebx = XOR of all {cs<<16|vec} = 0x0008000C
 *   ebp = XOR of all error codes = 0x00000040
 *   ecx = (nGP<<16)|(nNP<<4)|nSS = 0x00080081
 *   esi = total deliveries (17)  edx = 0x600D600D pass magic (dx -> 0xF4)
 *
 * Memory plan (NO paging): GDT @0x500 (17 entries, limit 0x87), IDT @0x1000
 * (gates 11/12/13 -> handlers; 32 = LDT desc; 33 = P=0 int32; 34/35 = present
 * int32 -> 0x68/0x70; 36/37 = present int32 -> LDT 0x000C/0x0014), LDT @0x3000
 * (4 entries: null, P=0 data, P=0 code, null; GDT[16] = its descriptor),
 * markers @0x2000..0x2110, TSS @0x4000 (SS0=0x10, ESP0=0x6000), stacks: CPL0
 * 0x7000, ring3 0x5000, TSS0 0x6000.
 *
 * GNU-as syntax; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
 */

.set GDT,     0x00000500
.set IDT,     0x00001000
.set MARK,    0x00002000      /* 17 case slots x 2 dwords: 0x2000..0x2087   */
.set CURSLOT, 0x000020F0      /* dword: the current case's slot address     */
.set SKIP,    0x000020F4      /* dword: bytes to skip past the faulting insn*/
.set DELCNT,  0x000020F8      /* dword: total deliveries                    */
.set V13CNT,  0x00002100      /* dword: #GP deliveries                      */
.set V11CNT,  0x00002104      /* dword: #NP deliveries                      */
.set V12CNT,  0x00002108      /* dword: #SS deliveries                      */

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

    /* ---- GDT @ 0x500 (17 entries, limit 0x87). P=0 entries carry access
     * bytes with the P bit (0x80) CLEAR: 0x12 = S|data-rw, 0x72 = S|DPL3|data,
     * 0x1A = S|code-x/r, 0x02 = system/LDT. GDT[16] (the present LDT
     * descriptor for fam 4b) is built in pm_entry together with the LDT. ---- */
    movl    $0x00000000, 0x0500         /* 0x00 null */
    movl    $0x00000000, 0x0504
    movl    $0x0000FFFF, 0x0508         /* 0x08 code32 DPL0 (0x9A) */
    movl    $0x00CF9A00, 0x050C
    movl    $0x0000FFFF, 0x0510         /* 0x10 data32 DPL0 (0x92) */
    movl    $0x00CF9200, 0x0514
    movl    $0x0000FFFF, 0x0518         /* 0x18 code32 DPL3 (0xFA) -> 0x1B */
    movl    $0x00CFFA00, 0x051C
    movl    $0x0000FFFF, 0x0520         /* 0x20 data32 DPL3 (0xF2) -> 0x23 */
    movl    $0x00CFF200, 0x0524
    movl    $0x00000000, 0x0528         /* 0x28 LDT descriptor, P=0 (S=0,type2) */
    movl    $0x00000200, 0x052C
    movl    $0x0000FFFF, 0x0530         /* 0x30 P=0 data DPL0 (access 0x12) */
    movl    $0x00CF1200, 0x0534
    movl    $0x0000FFFF, 0x0538         /* 0x38 P=0 data DPL0 (fam 1b combined) */
    movl    $0x00CF1200, 0x053C
    movl    $0x0000FFFF, 0x0540         /* 0x40 P=0 data DPL3 (access 0x72) */
    movl    $0x00CF7200, 0x0544
    movl    $0x0000FFFF, 0x0548         /* 0x48 P=0 code DPL0 (access 0x1A) */
    movl    $0x00CF1A00, 0x054C
    movl    $0x0000FFFF, 0x0550         /* 0x50 P=0 data DPL0 (fam 1c control) */
    movl    $0x00CF1200, 0x0554
    movl    $0x0000FFFF, 0x0558         /* 0x58 P=0 data (fam2/fam5 combined) */
    movl    $0x00CF1200, 0x055C
    movl    $0x0000FFFF, 0x0560         /* 0x60 P=0 code (fam2/fam5 control) */
    movl    $0x00CF1A00, 0x0564
    movl    $0x0000FFFF, 0x0568         /* 0x68 P=0 data (fam4 combined tgt CS) */
    movl    $0x00CF1200, 0x056C
    movl    $0x0000FFFF, 0x0570         /* 0x70 P=0 code (fam4 control tgt CS) */
    movl    $0x00CF1A00, 0x0574
    /* 0x78 TSS descriptor: built in pm_entry (needs no labels, but keep the
     * real-mode section minimal) */

    movw    $0x0087, 0x0480             /* GDT limit = 17*8-1 */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0                  /* PE (no paging; MP/NE not needed) */

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
    movl    $0x00007000, %esp

    /* ---- zero the marker area 0x2000..0x2140 ---- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $80, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000: handlers for 11 (#NP), 12 (#SS), 13 (#GP); the
     * family-3/4 entries. ---- */
    movl    $IDT, %edi
    xorl    %eax, %eax
    movl    $512, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $np_handler, %ebx
    movl    $(IDT + 11*8), %edi
    call    set_gate0
    movl    $ss_handler, %ebx
    movl    $(IDT + 12*8), %edi
    call    set_gate0
    movl    $gp_handler, %ebx
    movl    $(IDT + 13*8), %edi
    call    set_gate0
    movl    $df_exit, %ebx
    movl    $(IDT + 8*8), %edi
    call    set_gate0
    movl    $pf_exit, %ebx
    movl    $(IDT + 14*8), %edi
    call    set_gate0

    /* IDT[32] = LDT descriptor (S=0, type 2, P=0): fam 3 combined -> #GP */
    movl    $0x00000000, (IDT + 32*8)
    movl    $0x00000200, (IDT + 32*8 + 4)
    /* IDT[33] = P=0 legal 32-bit interrupt gate (access 0x0E): fam 3 control */
    movl    $0x00080000, (IDT + 33*8)       /* sel 0x08, offset[15:0] = 0 */
    movl    $0x00000E00, (IDT + 33*8 + 4)   /* P=0 | DPL0 | type 0xE */
    /* IDT[34] = present int32 gate -> target CS 0x68 (P=0 DATA): fam 4 */
    movl    $0x00680000, (IDT + 34*8)
    movl    $0x00008E00, (IDT + 34*8 + 4)
    /* IDT[35] = present int32 gate -> target CS 0x70 (P=0 CODE): fam 4 ctl */
    movl    $0x00700000, (IDT + 35*8)
    movl    $0x00008E00, (IDT + 35*8 + 4)
    /* IDT[36] = present int32 gate -> LDT target CS 0x000C (TI=1, P=0 DATA):
     * fam 4b discriminator -> #GP(0x000C) */
    movl    $0x000C0000, (IDT + 36*8)
    movl    $0x00008E00, (IDT + 36*8 + 4)
    /* IDT[37] = present int32 gate -> LDT target CS 0x0014 (TI=1, P=0 CODE):
     * fam 4b control -> #NP(0x0014) */
    movl    $0x00140000, (IDT + 37*8)
    movl    $0x00008E00, (IDT + 37*8 + 4)

    movw    $0x07FF, 0x0490
    movl    $IDT, 0x0492
    lidt    0x0490

    /* ---- GDT[15] = 0x78: 32-bit TSS, base 0x4000, limit 0x67, access 0x89 -- */
    movl    $0x40000067, 0x0578
    movl    $0x00008900, 0x057C

    /* ---- TSS at 0x4000: SS0=0x10, ESP0=0x6000, empty I/O map ---- */
    movl    $0x00004000, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $0x00006000, 0x00004004     /* ESP0 */
    movl    $0x00000010, 0x00004008     /* SS0  */
    movw    $0x0068,     0x00004066     /* IOPB */
    movw    $0x0078, %ax
    ltr     %ax

    /* ---- fam 4b: GDT[16] = 0x80, a PRESENT LDT descriptor (base 0x3000,
     * limit 0x1F, access 0x82), and the LDT itself. LDT[1] (sel 0x000C) is a
     * P=0 DATA descriptor, LDT[2] (sel 0x0014) a P=0 valid CODE descriptor --
     * the fam-4b int-gate targets. ---- */
    movl    $0x3000001F, 0x0580           /* base[15:0]=0x3000, limit 0x1F */
    movl    $0x00008200, 0x0584           /* access 0x82 (P, S=0, type 2) */
    movl    $0x00000000, 0x3000           /* LDT[0] null */
    movl    $0x00000000, 0x3004
    movl    $0x0000FFFF, 0x3008           /* LDT[1] P=0 data DPL0 (access 0x12) */
    movl    $0x00CF1200, 0x300C
    movl    $0x0000FFFF, 0x3010           /* LDT[2] P=0 code DPL0 (access 0x1A) */
    movl    $0x00CF1A00, 0x3014
    movl    $0x00000000, 0x3018           /* LDT[3] null */
    movl    $0x00000000, 0x301C
    movw    $0x0080, %ax
    lldt    %ax

    /* ======================= CPL0 case battery ========================== */

    /* ---- fam 1a: DS <- 0x28 (P=0 SYSTEM desc) -> #GP(0x28) ---- */
    movl    $0x2000, CURSLOT
    movl    $2, SKIP
    movw    $0x28, %ax
    movw    %ax, %ds                    /* #GP here */

    /* ---- fam 1a control: DS <- 0x30 (P=0 valid data) -> #NP(0x30) ---- */
    movl    $0x2008, CURSLOT
    movl    $2, SKIP
    movw    $0x30, %ax
    movw    %ax, %ds                    /* #NP here */

    /* ---- fam 1c: SS <- 0x48 (P=0 CODE desc) -> #GP(0x48) ---- */
    movl    $0x2010, CURSLOT
    movl    $2, SKIP
    movw    $0x48, %ax
    movw    %ax, %ss                    /* #GP here (SS: must be writable data) */

    /* ---- fam 1c control: SS <- 0x50 (P=0 writable data, DPL=CPL=RPL) -> #SS */
    movl    $0x2018, CURSLOT
    movl    $2, SKIP
    movw    $0x50, %ax
    movw    %ax, %ss                    /* #SS here */

    /* ---- fam 2: direct ljmp -> 0x58 (P=0 DATA desc) -> #GP(0x58) ---- */
    movl    $0x2020, CURSLOT
    movl    $7, SKIP
    .byte   0xEA
    .long   0
    .word   0x0058                      /* #GP here (not a code segment) */

    /* ---- fam 2 control: direct ljmp -> 0x60 (P=0 code) -> #NP(0x60) ---- */
    movl    $0x2028, CURSLOT
    movl    $7, SKIP
    .byte   0xEA
    .long   0
    .word   0x0060                      /* #NP here */

    /* ---- fam 3: int $32 through a P=0 LDT "gate" -> #GP(0x102) ---- */
    movl    $0x2030, CURSLOT
    movl    $2, SKIP
    int     $32                         /* #GP here (illegal gate type) */

    /* ---- fam 3 control: int $33 through a P=0 legal int gate -> #NP(0x10A) */
    movl    $0x2038, CURSLOT
    movl    $2, SKIP
    int     $33                         /* #NP here */

    /* ---- fam 4: int $34, gate -> P=0 DATA target CS -> #GP ---- */
    movl    $0x2040, CURSLOT
    movl    $2, SKIP
    int     $34                         /* #GP here (target not code) */

    /* ---- fam 4 control: int $35, gate -> P=0 CODE target CS -> #NP ------ */
    movl    $0x2048, CURSLOT
    movl    $2, SKIP
    int     $35                         /* #NP here */

    /* ---- fam 4b: int $36, gate -> LDT (TI=1) P=0 DATA target CS -> #GP ---
     * The pushed error code blames the gate's LDT target CS selector with TI
     * PRESERVED: 0x000C, IDT=0 (a descriptor table entry, not the IDT),
     * EXT=0 (software INT). The bit asserts name a swapped bit directly. */
    movl    $0x2070, CURSLOT
    movl    $2, SKIP
    int     $36                         /* #GP here (target not code) */
    movl    0x2074, %eax
    call    chk_ti1_idt0_ext0

    /* ---- fam 4b control: int $37, gate -> LDT (TI=1) P=0 CODE target CS
     * -> #NP(0x0014): same TI/IDT/EXT form as the discriminator. ---------- */
    movl    $0x2078, CURSLOT
    movl    $2, SKIP
    int     $37                         /* #NP here */
    movl    0x207C, %eax
    call    chk_ti1_idt0_ext0

    /* ---- fam 5: RETF, popped CS = 0x58 (P=0 DATA) -> #GP(0x58) ----
     * The rejected RETF leaves ESP unchanged (H-02, both oracles); the
     * handler skips the 1-byte lret and the mainline drops the fake frame. */
    movl    $0x2050, CURSLOT
    movl    $1, SKIP
    pushl   $0x00000058                 /* CS  = P=0 DATA desc */
    pushl   $0xDEAD0000                 /* EIP (never reached) */
    lret                                /* #GP here */
    addl    $8, %esp                    /* drop the fake frame */

    /* ---- fam 5 control: RETF, popped CS = 0x60 (P=0 code) -> #NP(0x60) ---- */
    movl    $0x2058, CURSLOT
    movl    $1, SKIP
    pushl   $0x00000060                 /* CS  = P=0 code desc */
    pushl   $0xDEAD0000                 /* EIP (never reached) */
    lret                                /* #NP here */
    addl    $8, %esp

    /* ---- fam 7: protected LDS must be atomic on descriptor rejection -----
     * The offset half is deliberately different from ESI's sentinel. The P=0
     * selector raises #NP(0x30); both QEMU and the RTL must enter the handler
     * with ESI unchanged. This catches the tempting decoder-only repair that
     * commits the ordinary MOV writeback in S_EXEC before S_SEGLD faults. */
    movl    $0xDEADBEEF, 0x2200         /* m16:32 offset */
    movw    $0x0030,     0x2204         /* P=0 valid data selector */
    movl    $0xA55A1234, %esi
    movl    $0x2080, CURSLOT
    movl    $6, SKIP
    .byte   0xC5, 0x35                  /* lds esi,[disp32] */
    .long   0x00002200
    cmpl    $0xA55A1234, %esi
    jne     lds_atomic_fail

    /* ======================= descend to ring 3 (fam 1b) =================== */
    pushfl
    orl     $0x00003000, (%esp)         /* IOPL = 3: the ring-3 leg may out 0xF4 */
    popfl
    pushl   $0x00000023                 /* SS  = ring-3 data */
    pushl   $0x00005000                 /* ESP = the ring-3 stack */
    pushl   $0x0000001B                 /* CS  = ring-3 code */
    pushl   $r3_entry                   /* EIP */
    lret

    .global r3_entry
r3_entry:
    movw    $0x23, %ax                  /* the outer RETF nulled DS */
    movw    %ax, %ds

    /* ---- fam 1b: DS <- 0x38 (P=0 data DPL=0) at CPL3 -> #GP(0x38) ---- */
    movl    $0x2060, CURSLOT
    movl    $2, SKIP
    movw    $0x38, %ax
    movw    %ax, %ds                    /* #GP here (DPL < CPL) */
    /* The handler loads DPL0 DS=0x10. Its outer IRET correctly nulls DS
     * before returning to CPL3, so reload a usable selector before the next
     * data access. QEMU's permissive null-data uses are not an ISA oracle. */
    movw    $0x23, %ax
    movw    %ax, %ds

    /* ---- fam 1b control: DS <- 0x40 (P=0 data DPL=3) at CPL3 -> #NP(0x40) -- */
    movl    $0x2068, CURSLOT
    movl    $2, SKIP
    movw    $0x40, %ax
    movw    %ax, %ds                    /* #NP here */
    /* The same outer-return nulling applies to the control's handler. */
    movw    $0x23, %ax
    movw    %ax, %ds

    /* ======================= verify + fold + exit ========================= *
     * Verify every slot against the expected table (fail edi = 0x80|cases-
     * remaining), XOR-fold both witness streams into ebx/ebp, pack the
     * per-vector counters into ecx, then stage the pass record. */
    movl    $MARK, %esi
    movl    $exptab, %edi
    movl    $17, %ecx
    xorl    %ebx, %ebx                  /* XOR of {cs<<16|vec} */
    xorl    %ebp, %ebp                  /* XOR of error codes */
1:  movl    (%esi), %eax
    cmpl    (%edi), %eax
    jne     vrf_fail
    xorl    %eax, %ebx
    movl    4(%esi), %eax
    cmpl    4(%edi), %eax
    jne     vrf_fail
    xorl    %eax, %ebp
    addl    $8, %esi
    addl    $8, %edi
    decl    %ecx
    jnz     1b

    cmpl    $17, DELCNT
    je      2f
    movl    $0x90, %edi
    jmp     fail_exit
2:  cmpl    $8, V13CNT
    je      3f
    movl    $0x91, %edi
    jmp     fail_exit
3:  cmpl    $8, V11CNT
    je      4f
    movl    $0x92, %edi
    jmp     fail_exit
4:  cmpl    $1, V12CNT
    je      5f
    movl    $0x93, %edi
    jmp     fail_exit
5:
    movl    V13CNT, %ecx
    shll    $16, %ecx
    movl    V11CNT, %eax
    shll    $4, %eax
    orl     %eax, %ecx
    orl     V12CNT, %ecx                /* ecx = 0x00080081 */
    movl    DELCNT, %esi                /* 17 */
    movl    $0x42, %edi                 /* PASS */
    movl    $0x600D600D, %edx
    movl    %edi, %eax
    movw    $0xF4, %dx                  /* edx -> 0x600D00F4 */
    outb    %al, %dx                    /* IOPL == 3 at CPL == 3 */
9:  jmp     9b

vrf_fail:                               /* a slot mismatched the expected table */
    leal    0x80(%ecx), %edi            /* 0x80|cases-remaining names the case */
    jmp     fail_exit

lds_atomic_fail:
    movl    $0x97, %edi                 /* rejected LDS changed its GPR half */
    jmp     fail_exit

/* ============================ handlers ================================== *
 * #NP/#SS/#GP entries: reload DS (the ring-3 legs run with DS=0x23), count
 * the delivery, record {cs<<16|vector} + the error code into the current
 * case's slots, resume PAST the faulting instruction (SKIP bytes), IRET.
 * Frame (same- and cross-privilege alike): [esp]=err, [esp+4]=EIP.         */
    .align 16
    .global np_handler
np_handler:
    movw    $0x10, %ax
    movw    %ax, %ds
    incl    V11CNT
    movl    $11, %ebx
    jmp     h_common
    .align 16
    .global ss_handler
ss_handler:
    movw    $0x10, %ax
    movw    %ax, %ds
    incl    V12CNT
    movl    $12, %ebx
    jmp     h_common
    .align 16
    .global gp_handler
gp_handler:
    movw    $0x10, %ax
    movw    %ax, %ds
    incl    V13CNT
    movl    $13, %ebx
h_common:
    incl    DELCNT
    movl    CURSLOT, %edi
    movl    %cs, %eax                   /* r32 <- Sreg zero-extends */
    shll    $16, %eax
    orl     %ebx, %eax                  /* {handler CS << 16 | vector} */
    movl    %eax, (%edi)
    movl    (%esp), %eax                /* the error code */
    movl    %eax, 4(%edi)
    movl    SKIP, %eax
    addl    %eax, 4(%esp)               /* resume past the faulting insn */
    addl    $4, %esp                    /* discard the error code */
    iretl

    /* Unexpected faults: exit with a distinctive code. */
    .align 16
    .global df_exit
df_exit:
    movl    $0x7F, %edi
    jmp     fail_exit
    .align 16
    .global pf_exit
pf_exit:
    movl    $0x7E, %edi
    jmp     fail_exit

    /* Common fail exit: edi = the code; leaves as (edi[7:0]<<1)|1 under
     * QEMU's isa-debug-exit. */
    .align 16
    .global fail_exit
fail_exit:
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
    orl    $0x00008E00, %eax            /* P, DPL0, 32-bit interrupt gate */
    movl    %eax, 4(%edi)
    ret

    /* ---- fam-4b bit-level error-code assert (EAX = the pushed error code).
     * TI (bit 2) must be SET (the blamed selector is in the LDT), IDT (bit 1)
     * CLEAR (the code names a GDT/LDT descriptor, not the IDT entry), EXT
     * (bit 0) CLEAR (a software INT is internal to the program). Each bit
     * fails with its own code so a swapped-bit regression names the bit. */
chk_ti1_idt0_ext0:
    testl   $4, %eax
    jz      bit_ti_fail
    testl   $2, %eax
    jnz     bit_idt_fail
    testl   $1, %eax
    jnz     bit_ext_fail
    ret
bit_ti_fail:
    movl    $0x94, %edi                 /* TI bit wrong (dropped or set) */
    jmp     fail_exit
bit_idt_fail:
    movl    $0x95, %edi                 /* IDT bit wrong (must be 0) */
    jmp     fail_exit
bit_ext_fail:
    movl    $0x96, %edi                 /* EXT bit wrong (must be 0) */
    jmp     fail_exit

/* ===================== expected-witness table =========================== *
 * 17 entries x 2 dwords, in case order: {cs<<16|vector}, error code.       */
    .section .rodata
    .align 4
exptab:
    .long   0x0008000D, 0x00000028      /* fam 1a      #GP(0x28)  */
    .long   0x0008000B, 0x00000030      /* fam 1a ctl  #NP(0x30)  */
    .long   0x0008000D, 0x00000048      /* fam 1c      #GP(0x48)  */
    .long   0x0008000C, 0x00000050      /* fam 1c ctl  #SS(0x50)  */
    .long   0x0008000D, 0x00000058      /* fam 2       #GP(0x58)  */
    .long   0x0008000B, 0x00000060      /* fam 2 ctl   #NP(0x60)  */
    .long   0x0008000D, 0x00000102      /* fam 3       #GP(32*8+2) */
    .long   0x0008000B, 0x0000010A      /* fam 3 ctl   #NP(33*8+2) */
    .long   0x0008000D, 0x00000068      /* fam 4       #GP(0x68)  */
    .long   0x0008000B, 0x00000070      /* fam 4 ctl   #NP(0x70)  */
    .long   0x0008000D, 0x00000058      /* fam 5       #GP(0x58)  */
    .long   0x0008000B, 0x00000060      /* fam 5 ctl   #NP(0x60)  */
    .long   0x0008000D, 0x00000038      /* fam 1b      #GP(0x38)  */
    .long   0x0008000B, 0x00000040      /* fam 1b ctl  #NP(0x40)  */
    .long   0x0008000D, 0x0000000C      /* fam 4b      #GP(0x000C) TI preserved */
    .long   0x0008000B, 0x00000014      /* fam 4b ctl  #NP(0x0014) TI preserved */
    .long   0x0008000B, 0x00000030      /* fam 7       #NP(0x30), LDS atomic */

/* ===================== 16-bit reset stub @ 0xFFF0 ======================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off
    .word   0xF000
