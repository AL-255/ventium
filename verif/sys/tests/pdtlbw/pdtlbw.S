/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium task #102 — DATA-STORE-UNDER-PAGING micro-TLB regression (FE_PIPE).
 *
 * Reproduces, self-checking + bare-metal, the CWSDPMI INT 0x31 dispatcher data
 * corruption that gave DOS-Quake the bogus "Division by Zero".  ROOT CAUSE: the
 * +VEN_FE_PIPE registered micro-TLB (fe_dtlb_*) re-registered a translation in a
 * NON-translatable state.  A hardware TASK SWITCH saves the outgoing task state to
 * the TSS in S_TSW_SAVE -- a state that is excluded from the paged translate (TSS
 * is read/written physically) and leaves cur_lin=0 while cur_is_d still defaults to
 * 1.  The old re-registration fired anyway and cached {page=0, phys = the D-TLB
 * INDEX-0 entry's frame}: an INCONSISTENT entry.  The direct-mapped D-TLB is keyed
 * on lin[15:12], so pages 0x00, 0x10, 0x20, 0x30 ... all share index 0 -- exactly
 * the aliasing CWSDPMI hit (it pounds low memory / page 0 between the dispatcher's
 * vector store and the read-back).  That poisoned entry then mis-translated a
 * subsequent colliding-page access, dropping the dispatcher's vector store -> the
 * read came back 0 -> mis-dispatch -> #DE.
 *
 * The bug is FE_PIPE-SPECIFIC (only the registered micro-TLB has the re-register
 * window); a non-FE_PIPE build (combinational dtlb_lk_*) is immune.  This test runs
 * a real hardware task switch (INT via a TASK GATE) between a paged store and its
 * read-back on pages that collide at D-TLB index 0, so an FE_PIPE build WITHOUT the
 * fix mis-translates and FAILS, and WITH the fix PASSES.
 *
 * Self-checking via isa-debug-exit:  exit AL=0x42 -> status 133 on PASS, AL=0x21 ->
 * status 67 on FAIL.  No qemu-system golden is needed (the refs qemu-system oracle
 * is un-buildable here, so the formal verify-sys differential is blocked); the
 * comparison is done IN the guest and reported only through the exit status, so the
 * RTL TB validates it stand-alone.
 *
 * ---------------------------------------------------------------------------
 * Memory plan (-m 64; identity-mapped low RAM):
 *   PD    @ 0x00011000   PT0 @ 0x00012000 (FULL identity of [0,4MiB), P|RW|US, D=0)
 *   GDT   @ 0x00000500
 *   IDT   @ 0x00001000   (vector 0x40 = a TASK GATE -> TSS_B selector)
 *   TSS_A @ 0x00020000   (the running task's TSS; page 0x20, D-TLB index 0)
 *   TSS_B @ 0x00010000   (the INT-0x40 task; page 0x10, D-TLB index 0)
 *   TARGET page = 0x00030000 (page 0x30, D-TLB index 0).  Store/read @ 0x00030004.
 * All three TSS/target pages collide at D-TLB index 0 (lin[15:12]==0), so the
 * task-switch TSS save poisons the very index the target read consults.
 * ---------------------------------------------------------------------------
 */

    .equ  TARGET_LIN, 0x00030004
    .equ  SENTINEL,   0x31313131         /* the "vector 0x31" sentinel */
    .equ  TSS_A,      0x00020000
    .equ  TSS_B,      0x00010000

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

    /* --- GDT (8 entries) at linear 0x0500 --- */
    movl    $0x00000500, %ebx
    /* 0x00 null */
    movl    $0, 0(%ebx);  movl $0, 4(%ebx)
    /* 0x08 code32 DPL0 */
    movl    $0x0000FFFF, 8(%ebx);   movl $0x00CF9A00, 12(%ebx)
    /* 0x10 data32 DPL0 */
    movl    $0x0000FFFF, 16(%ebx);  movl $0x00CF9200, 20(%ebx)
    /* 0x18 code32 DPL3 */
    movl    $0x0000FFFF, 24(%ebx);  movl $0x00CFFA00, 28(%ebx)
    /* 0x20 data32 DPL3 */
    movl    $0x0000FFFF, 32(%ebx);  movl $0x00CFF200, 36(%ebx)
    /* TSS descriptor dword layout: lo = base[15:0]<<16 | limit[15:0];
     *                              hi = base[31:24]<<24 | flags<<16 | access<<8
     *                                   | base[23:16].
     * 32-bit available TSS: access=0x89, flags(+limit[19:16])=0x00.
     * 0x28 TSS_A base=0x00020000 limit=0x67: lo=0x00000067 hi=0x00008902 */
    movl    $0x00000067, 40(%ebx);  movl $0x00008902, 44(%ebx)
    /* 0x30 TSS_B base=0x00010000 limit=0x67: lo=0x00000067 hi=0x00008901 */
    movl    $0x00000067, 48(%ebx);  movl $0x00008901, 52(%ebx)

    /* gdt pseudo-descriptor @0x0480 (8 entries -> limit 0x3F) */
    movw    $0x003F, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    /* enter protected mode */
    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA
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
    movl    $0x00090000, %esp

    /* ---- page tables: PT0 FULL identity of [0,4MiB), P|RW|US, D=0 ---- */
    movl    $0x00012000, %edi
    movl    $0x00000007, %eax
    movl    $1024, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x00011000, %edi
    movl    $0x00012007, 0(%edi)          /* PD[0]->PT0 P|RW|US */

    /* ---- TSS_A @ 0x20000: the CURRENT task's TSS (CPU saves outgoing state here
     * across the switch).  Zero it; set the I/O map base. ---- */
    movl    $TSS_A, %edi
    movl    $26, %ecx
    xorl    %eax, %eax
2:  movl    %eax, (%edi);  addl $4, %edi;  loop 2b
    movw    $0x0068, (TSS_A + 0x66)       /* I/O map base (empty) */

    /* ---- TSS_B @ 0x10000: the target task image.  When switched to, it runs the
     * CPL0 checker `tssb_entry` with paging still enabled (CR3 = our PD).  Fields:
     * CR3@0x1C EIP@0x20 EFLAGS@0x24 ESP@0x38 ES@0x48 CS@0x4C SS@0x50 DS@0x54
     * FS@0x58 GS@0x5C LDTR@0x60 IObase@0x66. ---- */
    movl    $TSS_B, %edi
    movl    $26, %ecx
    xorl    %eax, %eax
3:  movl    %eax, (%edi);  addl $4, %edi;  loop 3b
    movl    $0x00011000, (TSS_B + 0x1C)   /* CR3 = our page directory */
    movl    $tssb_entry,  (TSS_B + 0x20)  /* EIP */
    movl    $0x00000002,  (TSS_B + 0x24)  /* EFLAGS (IF=0) */
    movl    $0x00091000,  (TSS_B + 0x38)  /* ESP (flat CPL0 stack) */
    movl    $0x00000010,  (TSS_B + 0x48)  /* ES */
    movl    $0x00000008,  (TSS_B + 0x4C)  /* CS */
    movl    $0x00000010,  (TSS_B + 0x50)  /* SS */
    movl    $0x00000010,  (TSS_B + 0x54)  /* DS */
    movl    $0x00000010,  (TSS_B + 0x58)  /* FS */
    movl    $0x00000010,  (TSS_B + 0x5C)  /* GS */
    movl    $0x00000000,  (TSS_B + 0x60)  /* LDTR = 0 */
    movw    $0x0068,      (TSS_B + 0x66)  /* I/O map base */

    /* ---- enable paging ---- */
    movl    $0x00011000, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* LTR 0x28: TR = TSS_A (the running task) */
    movw    $0x28, %ax
    ltr     %ax

    /* seed the target word to 0 (paged write; this dirties page 0x30, fine -- the
     * bug is in the TASK-SWITCH-poisoned read translation, not the store's own
     * set-D).  We WANT the physical 0x30004 to hold 0 so a mistranslated read of a
     * DIFFERENT page shows up as a mismatch. */
    xorl    %eax, %eax
    movl    %eax, TARGET_LIN

    /* register the target page in the micro-TLB via a read (now resident, index 0) */
    movl    TARGET_LIN, %eax

    /* STORE the sentinel to the target (16-bit-PM form, like the dispatcher) */
    movl    $SENTINEL, %eax
    .byte   0x66
    movl    %eax, TARGET_LIN              /* mov word [0x30004], ax */
    .byte   0x66
    movl    %eax, (TARGET_LIN + 2)        /* mov word [0x30006], ax */

    /* THE HARDWARE TASK SWITCH: a far JMP to the TSS_B selector (0x30).  The CPU
     * SAVES TSS_A (page 0x20, D-TLB index 0) in S_TSW_SAVE and READS TSS_B (page
     * 0x10, D-TLB index 0) in S_TSW_READ -- both NON-translatable states that,
     * pre-fix, poison the index-0 micro-TLB entry (which the target page 0x30 also
     * indexes), so the incoming task's read-back of 0x30004 mis-translates. */
    ljmp    $0x30, $0

    /* the task switch does not return here (TSS_B runs tssb_entry and exits) */
4:  jmp     4b

    /* ===================== TSS_B task: the checker ===================== */
    .global tssb_entry
tssb_entry:
    /* running as the INT-0x40 task at CPL0 with paging on.  Read the target linear
     * back; identity map => physical 0x30004.  If the task-switch poisoned the
     * index-0 micro-TLB, this read translates to the WRONG physical and misses the
     * sentinel. */
    movl    TARGET_LIN, %edx
    movl    $SENTINEL, %ecx
    cmpl    %ecx, %edx
    jne     fail

    movl    $0x42, %eax                   /* PASS -> status 133 */
    movw    $0xF4, %dx
    outb    %al, %dx
hangp:
    hlt
    jmp     hangp

fail:
    movl    $0x21, %eax                   /* FAIL -> status 67 */
    movw    $0xF4, %dx
    outb    %al, %dx
hangf:
    hlt
    jmp     hangf

    /* ===================== 16-bit reset stub @ 0xFFF0 ===================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
