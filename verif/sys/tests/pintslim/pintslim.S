/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * pintslim — cross-privilege interrupt-frame STACK-LIMIT regression for the
 * S_INT_PROBE frame pre-probe's segment-extent check (the check is live only
 * in the +VEN_SEG_ENFORCE variant build; the canonical build computes it as
 * diagnostic-only, and QEMU does not limit-check frame pushes at all -- so
 * the discrimination is graded per build, the psmmmeta case-D pattern).
 *
 * THE DEFECT CLASS: the probe's segment extent used to follow the dword
 * default (4) for every frame slot, so a 16-bit gate's WORD slot ending
 * exactly at the stack segment's bound -- the last legal word -- was
 * rejected with #SS. The probe now checks each slot-start page with the
 * slot's own width (int_frm_wide ? 4 : 2), so exactly-at-bound succeeds and
 * only a slot genuinely past the bound faults.
 *
 * THE MATRIX: stack B bit (0 = 16-bit/64K window, 1 = 32-bit) x segment form
 * (expand-up: legal offsets [0, limit]; expand-down: legal offsets (limit,
 * 0xFFFF / 0xFFFFFFFF]) x frame width (16-bit gate = 5 word slots, 32-bit
 * gate = 5 dword slots; a software INT has no error code) x {the frame's
 * FIRST push slot ends EXACTLY at the bound (must succeed), one slot-width
 * past it (must #SS, pre-commit -- zero frame bytes written)}. 16 cases,
 * driven from one table (case_table below):
 *
 *   expand-up,   limit 0xFFFC: at-bound ESP0 = 0xFFFD (first slot's last
 *     byte == the limit); past ESP0 = limit+1+unit (first slot starts past
 *     the limit; the B=0 dword case wraps the 64K window and its first slot
 *     starts at 0xFFFD -- still out past 0xFFFC).
 *   expand-down, limit 0xFF00: at-bound ESP0 = 0 (the first slot ends at
 *     the upper bound -- 0xFFFF for B=0, 0xFFFFFFFF for B=1); past tests the
 *     OTHER bound: B=0 uses ESP0 = limit+unit (the first slot starts AT the
 *     lower bound, which is out for expand-down), B=1 uses ESP0 = 1 (the
 *     first slot's extent wraps past 4 GiB -- caught by the 33-bit extent
 *     check). The past placements are chosen so the frame never wraps the
 *     masked stack window, keeping the delivered frame contiguous for the
 *     non-enforcing oracles' content check.
 *
 * Every stack segment is based at its own 64 KiB window (0x30000..0x60000)
 * so the frame bytes land at known physical addresses (expand-down B=1 wraps
 * the 4 GiB linear space: base + 0xFFFFFFxx lands just below the base). The
 * ring-3 driver rewrites TSS.SS0:ESP0 per case, lays a 32-byte sentinel over
 * the frame window, and invokes the gate through a per-vector stub. The
 * CPL0 handlers record the delivered frame (ESP + the CS/SP/SS slots) and
 * stamp the case slot 0xAA; under enforcement the probe instead raises
 * #SS(0) pre-commit, delivered to a CPL3 #SS handler through a DPL3 gate
 * (same-privilege frame on the USER stack -- the TSS stack is not involved,
 * so the faulting delivery cannot cascade), which stamps 0x55 after checking
 * err == 0 and the saved EIP == the int instruction, then resumes past it.
 *
 * PER-BUILD EXPECTATIONS (asserted by run-pintslim-gate.sh):
 *   canonical + QEMU free-run : every case delivers (the limit check is
 *                               inert); esi (SS_SEEN) = 0, ebp (PAST_DLVR)
 *                               = 0xAAAA, ecx (SENTINEL intact) = 0.
 *   +VEN_SEG_ENFORCE          : the 8 at-bound cases deliver, the 8 past
 *                               cases #SS(0) pre-commit: esi = 0xAAAA,
 *                               ecx = 0xAAAA, ebp = 0, and +ven_faultlog
 *                               shows exactly 8x vec=12 err=0.
 * Every build           : ebx (AT_OK | R-case bits) = 0x000F5555, edi = 0x42 (the
 *                               in-image self-checks all passed),
 *                               edx = 0x600D00F4.
 *
 * THE R CASES (CPL0, same-privilege, before the ring-3 half): a 16-bit
 * IRETW pops a 3-word frame whose topmost word (FLAGS at SP+4) ends exactly
 * at the stack segment's bound -- R0/R1 expand-up limit 0xFFFC (SP=0xFFF7,
 * both B forms), R2 expand-down B=0 (SP=0xFFFA, FLAGS ends at 0xFFFF), R3
 * expand-down B=1 (SP=0xFFFFFFFA, FLAGS ends at 0xFFFFFFFF). The pop path's
 * bus reads are dword-granular, so the segment extent check must charge the
 * architectural 2 bytes (seg_ext_ovr in the S_IRET arm); a build without it
 * false-#SS's at the iretw (caught by h_ss0 -> fail exit 0x70+i). The
 * 16-bit return stub records the RETURNED FLAGS word (restoration witness,
 * expected 0x08D5 after masking) and far-jumps back; reaching the rdone
 * block proves the CS/IP restoration.
 *
 * The canonical run is ALSO a full differential vs the QEMU golden (no SMM,
 * no port-0x92 -- every flow here is architectural and identical in both
 * oracles when enforcement is off).
 *
 * Memory plan: GDT @0x500 (0x08 code32 DPL0 base 0xF0000, 0x10 data32 DPL0
 * flat, 0x18 code16 DPL0 base 0xF0000, 0x20 code32 DPL3 base 0xF0000, 0x28
 * data32 DPL3 flat, 0x30 TSS @0x8000, 0x40/0x48 EU stacks B=0/B=1 limit
 * 0xFFFC, 0x50/0x58 ED stacks B=0/B=1 limit 0xFF00), IDT @0x1000 (12 -> h_ss
 * via a 32-bit DPL3 gate; 0x40/0x41 16-bit DPL3 gates -> h16; 0x42/0x43
 * 32-bit DPL3 gates -> h32), TSS @0x8000, markers @0x2000..0x20FF, case
 * result slots @0x2100, stacks: ring-3 0x5000, CPL0 setup 0x7000, case
 * windows 0x30000/0x40000/0x50000/0x60000.
 * GNU-as; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
 */

.set TSS,      0x00008000
.set CUR_SLOT, 0x000020F0
.set CUR_EIP,  0x000020F4
.set CUR_LO,   0x000020F8
.set CUR_SP,   0x000020E8
.set CUR_ESP,  0x000020EC
.set CUR_RCODE,0x000020E0
.set CUR_FLAGS,0x000020E4
.set AT_OK,    0x00002000
.set SS_SEEN,  0x00002004
.set SENT_OK,  0x00002008
.set PAST_DLV, 0x00002010
.set SLOTS,    0x00002100

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

    /* GDT @ 0x500 (12 entries, limit 0x5F). All code segments are based at
     * 0xF0000 so every offset is 16-bit clean (the 16-bit frames push WORD
     * IPs; IRETW must land exactly). */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000FFFF, 0x0508        /* 0x08 code32 DPL0 base 0xF0000 */
    movl    $0x00CF9A0F, 0x050C
    movl    $0x0000FFFF, 0x0510        /* 0x10 data32 DPL0 flat */
    movl    $0x00CF9200, 0x0514
    movl    $0x0000FFFF, 0x0518        /* 0x18 code16 DPL0 base 0xF0000 (D=0) */
    movl    $0x008F9A0F, 0x051C
    movl    $0x0000FFFF, 0x0520        /* 0x20 code32 DPL3 base 0xF0000 */
    movl    $0x00CFFA0F, 0x0524
    movl    $0x0000FFFF, 0x0528        /* 0x28 data32 DPL3 flat */
    movl    $0x00CFF200, 0x052C
    movl    $0x80000067, 0x0530        /* 0x30 TSS base 0x8000 limit 0x67 */
    movl    $0x00008900, 0x0534
    /* the four boundary stack segments (data, W, P, DPL0; G=0):
     *   0x40 expand-up   B=0 limit 0xFFFC base 0x30000
     *   0x48 expand-up   B=1 limit 0xFFFC base 0x40000
     *   0x50 expand-down B=0 limit 0xFF00 base 0x50000
     *   0x58 expand-down B=1 limit 0xFF00 base 0x60000                    */
    movl    $0x0000FFFC, 0x0540
    movl    $0x00009203, 0x0544
    movl    $0x0000FFFC, 0x0548
    movl    $0x00409204, 0x054C
    movl    $0x0000FF00, 0x0550
    movl    $0x00009605, 0x0554
    movl    $0x0000FF00, 0x0558
    movl    $0x00409606, 0x055C
    movw    $0x005F, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA
    .long   _pm32_off
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
    movl    $0x00007000, %esp

    /* zero markers 0x2000..0x20FF and the result slots 0x2100..0x213F */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $80, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* ---- IDT @ 0x1000. 16-bit gate: lo = (sel<<16)|off16, hi = attr<<8.
     * 32-bit gate: lo = (sel<<16)|off[15:0], hi = off[31:16]|attr<<8. ----- */
    /* vector 12 (#SS) @ 0x1060: while the CPL0 R-cases run this is a 32-bit
     * INT gate DPL0 (attr 0x8E), sel 0x08 -> h_ss0, so a (broken-build) #SS
     * from an R-case iretw lands in a CPL0 handler that exits loudly. The
     * ring-3 driver re-arms this vector to the DPL3 h_ss gate before any
     * ring-3 case runs. */
    movl    $_hss0_off, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1060
    movl    $_hss0_off, %eax
    shrl    $16, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 0x1064
    /* 0x40 @ 0x1200 / 0x41 @ 0x1208: 16-bit INT gates DPL3 (attr 0xE6),
     * sel 0x18 -> h16 */
    movl    $_h16_off, %eax
    orl     $0x00180000, %eax
    movl    %eax, 0x1200
    movl    $0x0000E600, 0x1204
    movl    $_h16_off, %eax
    orl    $0x00180000, %eax
    movl    %eax, 0x1208
    movl    $0x0000E600, 0x120C
    /* 0x42 @ 0x1210 / 0x43 @ 0x1218: 32-bit INT gates DPL3 (attr 0xEE),
     * sel 0x08 -> h32 */
    movl    $_h32_off, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1210
    movl    $_h32_off, %eax
    shrl    $16, %eax
    orl     $0x0000EE00, %eax
    movl    %eax, 0x1214
    movl    $_h32_off, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1218
    movl    $_h32_off, %eax
    shrl    $16, %eax
    orl     $0x0000EE00, %eax
    movl    %eax, 0x121C
    movw    $0x07FF, 0x0490            /* IDT limit */
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- TSS @ 0x8000: zeroed, empty I/O map; SS0:ESP0 per case --------- */
    movl    $TSS, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movw    $0x0068, TSS+0x66
    movl    $0x00006000, TSS+0x04      /* inert initial ESP0/SS0 (never used */
    movl    $0x00000010, TSS+0x08      /*  before the first case rewrites)   */
    movw    $0x0030, %ax
    ltr     %ax

    /* ==================== R cases: the 16-bit IRETW pop extent =============
     * A 16-bit IRETW whose topmost popped WORD (FLAGS at SP+4) ends exactly
     * at the stack segment's bound must return cleanly: the pop path's bus
     * reads are dword-granular, but the segment extent check must charge
     * the architectural 2 bytes. Four same-privilege CPL0 cases, one per
     * stack form:
     *   R0: expand-up   B=0 limit 0xFFFC -- SP = 0xFFF7 (FLAGS [0xFFFB,FFFC])
     *   R1: expand-up   B=1 limit 0xFFFC -- SP = 0xFFF7 (same, unmasked)
     *   R2: expand-down B=0 limit 0xFF00 -- SP = 0xFFFA (FLAGS ends 0xFFFF)
     *   R3: expand-down B=1 limit 0xFF00 -- SP = 0xFFFFFFFA (ends 0xFFFFFFFF)
     * Each builds a 3-word frame (IP = a 16-bit return stub, CS = 0x18,
     * FLAGS = a distinctive word) directly on the boundary stack and iretws.
     * The stub records the RETURNED FLAGS (restoration check) and far-jumps
     * back to the case's rdone block; reaching rdone proves the CS/IP
     * restoration. A broken build #SS's at the iretw and lands in h_ss0,
     * which exits with the case's CUR_RCODE. */
    movl    $(0x70 + 0), CUR_RCODE
    movw    $0x40, %ax                    /* R0: expand-up B=0 */
    movw    %ax, %ss
    movl    $0x0000FFF7, %esp
    movw    $_r16r0_off, 0(%esp)
    movw    $0x0018, 2(%esp)
    movw    $0x38D7, 4(%esp)
    iretw
    .global rdone0, rdone1, rdone2, rdone3
rdone0:
    movw    $0x10, %ax
    movw    %ax, %ss
    movl    $0x00007000, %esp
    movw    CUR_FLAGS, %ax
    andw    $0x0FD5, %ax
    cmpw    $0x08D5, %ax
    je      1f
    movl    $(0x70 + 0), %edi
    jmp     fail_exit
1:  orl     $0x00010000, AT_OK

    movl    $(0x70 + 1), CUR_RCODE
    movw    $0x48, %ax                    /* R1: expand-up B=1 */
    movw    %ax, %ss
    movl    $0x0000FFF7, %esp
    movw    $_r16r1_off, 0(%esp)
    movw    $0x0018, 2(%esp)
    movw    $0x38D7, 4(%esp)
    iretw
rdone1:
    movw    $0x10, %ax
    movw    %ax, %ss
    movl    $0x00007000, %esp
    movw    CUR_FLAGS, %ax
    andw    $0x0FD5, %ax
    cmpw    $0x08D5, %ax
    je      1f
    movl    $(0x70 + 1), %edi
    jmp     fail_exit
1:  orl     $0x00020000, AT_OK

    movl    $(0x70 + 2), CUR_RCODE
    movw    $0x50, %ax                    /* R2: expand-down B=0 */
    movw    %ax, %ss
    movl    $0x0000FFFA, %esp
    movw    $_r16r2_off, 0(%esp)
    movw    $0x0018, 2(%esp)
    movw    $0x38D7, 4(%esp)
    iretw
rdone2:
    movw    $0x10, %ax
    movw    %ax, %ss
    movl    $0x00007000, %esp
    movw    CUR_FLAGS, %ax
    andw    $0x0FD5, %ax
    cmpw    $0x08D5, %ax
    je      1f
    movl    $(0x70 + 2), %edi
    jmp     fail_exit
1:  orl     $0x00040000, AT_OK

    movl    $(0x70 + 3), CUR_RCODE
    movw    $0x58, %ax                    /* R3: expand-down B=1 */
    movw    %ax, %ss
    movl    $0xFFFFFFFA, %esp
    movw    $_r16r3_off, 0(%esp)
    movw    $0x0018, 2(%esp)
    movw    $0x38D7, 4(%esp)
    iretw
rdone3:
    movw    $0x10, %ax
    movw    %ax, %ss
    movl    $0x00007000, %esp
    movw    CUR_FLAGS, %ax
    andw    $0x0FD5, %ax
    cmpw    $0x08D5, %ax
    je      1f
    movl    $(0x70 + 3), %edi
    jmp     fail_exit
1:  orl     $0x00080000, AT_OK

    /* re-arm vector 12 for the ring-3 half: 32-bit INT gate DPL3 (attr
     * 0xEE), sel 0x20 -> h_ss (a CPL3 handler, so the faulted delivery's own
     * frame is SAME-privilege on the user stack -- the TSS boundary stack is
     * never re-entered and the #SS cannot cascade). */
    movl    $_hss_off, %eax
    orl     $0x00200000, %eax
    movl    %eax, 0x1060
    movl    $_hss_off, %eax
    shrl    $16, %eax
    orl     $0x0000EE00, %eax
    movl    %eax, 0x1064

    /* IOPL = 3 so the ring-3 legs may drive port 0xF4 at the exit. */
    pushfl
    orl     $0x00003000, (%esp)
    popfl

    /* ---- transfer DOWN to ring 3 via the outer RETF (pjmpgate mechanism) - */
    pushl   $0x0000002B                /* SS  = ring-3 data, RPL 3 */
    pushl   $0x00005000                /* ESP = the ring-3 stack */
    pushl   $0x00000023                /* CS  = ring-3 code, RPL 3 */
    pushl   $_r3_off                   /* EIP = r3_entry - 0xF0000 */
    lret

/* ============================ ring 3 ===================================== *
 * The case driver. Table entry (6 dwords): {esp0, ss0_sel, stub_off, K,
 * base, mask}. The stub is a ring-3 `int $N; retl`; its offset doubles as
 * the EIP the #SS handler must see saved. Even cases are the at-bound
 * (must-deliver) half, odd cases the one-past (must-#SS under enforcement)
 * half. */
    .global r3_entry
r3_entry:
    movw    $0x2B, %ax                 /* the outer RETF NULLED DS (DPL 0 < 3) */
    movw    %ax, %ds
    xorl    %ebx, %ebx                 /* case index */
case_loop:
    cmpl    $16, %ebx
    je      cases_done
    movl    %ebx, %eax
    imull   $24, %eax, %eax
    leal    case_table(%eax), %esi
    /* TSS.SS0:ESP0 <- the case's boundary stack */
    movl    0(%esi), %eax
    movl    %eax, TSS+0x04
    movl    4(%esi), %eax
    movl    %eax, TSS+0x08
    /* CUR_SLOT + clear it */
    movl    %ebx, %eax
    shll    $2, %eax
    addl    $SLOTS, %eax
    movl    %eax, CUR_SLOT
    movl    $0, (%eax)
    /* sentinel: 32 bytes starting at lo = base + ((esp0 - K) & mask). The
     * frame's K bytes occupy [lo, lo+K): slots start at masked offsets
     * descending from the boundary, each slot's bytes spanning unit bytes
     * linearly upward, so the frame is contiguous from lo. */
    movl    0(%esi), %eax
    subl    12(%esi), %eax
    andl    20(%esi), %eax
    addl    16(%esi), %eax             /* + base -> lo */
    movl    %eax, CUR_LO
    movl    $0x5A5A5A5A, %edx
    movl    %edx, 0(%eax)
    movl    %edx, 4(%eax)
    movl    %edx, 8(%eax)
    movl    %edx, 12(%eax)
    movl    %edx, 16(%eax)
    movl    %edx, 20(%eax)
    movl    %edx, 24(%eax)
    movl    %edx, 28(%eax)
    /* the int stub: record its int instruction's EIP for the #SS check, and
     * the pre-call ESP for the handlers' saved-SP check (the near call to
     * the stub pushes 4 bytes, so the interrupted SP is CUR_SP-4) */
    movl    %esp, CUR_SP
    movl    8(%esi), %eax
    movl    %eax, CUR_EIP
    call    *%eax                      /* int $N; retl (either path returns) */
    movw    $0x2B, %ax                 /* a cross-priv IRET nulled DS again */
    movw    %ax, %ds
    /* reload the table pointer (esi survives; nothing else may) */
    movl    %ebx, %eax
    imull   $24, %eax, %eax
    leal    case_table(%eax), %esi
    movl    CUR_SLOT, %edi
    movl    (%edi), %eax               /* the case result */
    testl   $1, %ebx
    jnz     past_case
    /* ---------------- at-bound case: must have DELIVERED (slot 0xAA) ----- */
    cmpl    $0xAA, %eax
    je      1f
    leal    0x20(%ebx), %edi
    jmp     fail_exit
1:  /* handler ESP must be (esp0 - K) & mask (the upper half is the old
     * ring-3 ESP's, which is 0) */
    movl    0(%esi), %eax
    subl    12(%esi), %eax
    andl    20(%esi), %eax
    cmpl    %eax, CUR_ESP
    je      2f
    leal    0x60(%ebx), %edi
    jmp     fail_exit
2:  movl    $1, %eax
    movl    %ebx, %ecx
    shll    %cl, %eax
    orl     %eax, AT_OK
    jmp     next_case
    /* ---------------- one-past case: 0x55 (#SS) or 0xAA (delivered) ------- */
past_case:
    cmpl    $0x55, %eax
    jne     3f
    /* #SS path (the enforcing build): zero frame bytes -- the whole sentinel
     * window must be intact */
    movl    $1, %eax
    movl    %ebx, %ecx
    shll    %cl, %eax
    orl     %eax, SS_SEEN
    movl    CUR_LO, %eax
    movl    $8, %ecx
4:  cmpl    $0x5A5A5A5A, (%eax)
    jne     5f
    addl    $4, %eax
    loop    4b
    movl    $1, %eax
    movl    %ebx, %ecx
    shll    %cl, %eax
    orl     %eax, SENT_OK
    jmp     next_case
5:  leal    0x40(%ebx), %edi           /* #SS but frame bytes were written */
    jmp     fail_exit
3:  cmpl    $0xAA, %eax
    je      6f
    leal    0x30(%ebx), %edi           /* neither #SS nor delivered?! */
    jmp     fail_exit
6:  /* delivered path (canonical build / QEMU): the handler's ESP check is
     * the same as at-bound, and the frame must have overwritten the sentinel */
    movl    0(%esi), %eax
    subl    12(%esi), %eax
    andl    20(%esi), %eax
    cmpl    %eax, CUR_ESP
    je      7f
    leal    0x60(%ebx), %edi
    jmp     fail_exit
7:  movl    CUR_LO, %eax
    movl    $8, %ecx
8:  cmpl    $0x5A5A5A5A, (%eax)
    jne     9f                         /* a frame byte landed */
    addl    $4, %eax
    loop    8b
    leal    0x50(%ebx), %edi           /* "delivered" but no frame bytes */
    jmp     fail_exit
9:  movl    $1, %eax
    movl    %ebx, %ecx
    shll    %cl, %eax
    orl     %eax, PAST_DLV
next_case:
    incl    %ebx
    jmp     case_loop

    /* ======================= exit: fold the witnesses ===================== */
cases_done:
    movl    AT_OK, %ebx                /* 0x5555 in every build */
    movl    SS_SEEN, %esi              /* 0 canonical / 0xAAAA enforcing */
    movl    SENT_OK, %ecx              /* 0 canonical / 0xAAAA enforcing */
    movl    PAST_DLV, %ebp             /* 0xAAAA canonical / 0 enforcing */
    movl    $0x42, %edi                /* every self-check passed */
    movl    $0x600D600D, %edx
    movl    $0x42, %eax
    movw    $0xF4, %dx                 /* edx -> 0x600D00F4 */
    outb    %al, %dx
9:  jmp     9b

    .align 16
    .global fail_exit
fail_exit:                              /* edi = the failing check's code */
    movl    %edi, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b

/* ===================== ring-3 int stubs (int $N; retl) =================== */
    .align 16
    .global i40
i40: int $0x40
    retl
    .global i41
i41: int $0x41
    retl
    .global i42
i42: int $0x42
    retl
    .global i43
i43: int $0x43
    retl

/* ===================== ring-3 #SS handler (32-bit) ======================= *
 * Same-privilege frame on the user stack: [0]=err [4]=EIP [8]=CS
 * [12]=EFLAGS. The contract: err == 0 and the saved EIP is the int
 * instruction (the delivery restarts it). DS is still 0x2B (a same-priv
 * delivery nulls nothing). */
    .align 16
    .global h_ss
h_ss:
    movl    $0xE5, %eax
    cmpl    $0, 0(%esp)                /* error code 0 */
    jne     1f
    movl    CUR_EIP, %ecx
    cmpl    %ecx, 4(%esp)              /* saved EIP == the int instruction */
    jne     1f
    movl    $0x55, %eax
1:  movl    CUR_SLOT, %edi             /* (%edi) is DS-relative */
    movl    %eax, (%edi)
    addl    $2, 4(%esp)                /* saved EIP: resume past the int imm8 */
    addl    $4, %esp                   /* IRET does not pop the error code -- */
    iretl                              /* drop it first (the handler's job)  */

/* ===================== CPL0 16-bit-gate handler (16-bit code) ============ *
 * Frame words: [0]=IP [2]=CS [4]=FLAGS [6]=SP [8]=SS. Runs on the case's
 * boundary stack: no pushes, frame reads via SS:EBP only. 32-bit addressing
 * (addr32 prefixes) so B=1 stacks (ESP past 64K) read correctly.
 *
 * The return CANNOT iretw off the boundary stack: the pop path's bus reads
 * are dword-granular, and the segment check follows the read extent, so the
 * topmost pop (a word ending exactly at the bound -- the case's whole
 * point) would be extent-4 checked past it and false-#SS under enforcement.
 * So the handler reads the five frame words with (legal, word-wide) loads,
 * rebuilds the same frame on the flat CPL0 scratch stack, and iretws from
 * there. The delivery -- the thing this test grades -- is unaffected. */
    .code16
    .align 16
    .global h16
h16:
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    %esp, %ebp
    movl    %ebp, CUR_ESP
    movw    0(%ebp), %cx             /* IP */
    movw    2(%ebp), %dx             /* CS */
    movw    4(%ebp), %si             /* FLAGS */
    movw    6(%ebp), %di             /* SP */
    movw    8(%ebp), %bp             /* SS (ebp free after this) */
    /* switch to the flat scratch stack and rebuild the return frame there */
    movw    $0x10, %ax
    movw    %ax, %ss
    movl    $0x00006FF6, %esp
    movw    %cx, 0(%esp)             /* IP */
    movw    %dx, 2(%esp)             /* CS */
    movw    %si, 4(%esp)             /* FLAGS */
    movw    %di, 6(%esp)             /* SP */
    movw    %bp, 8(%esp)             /* SS */
    /* validate (the registers still hold the delivered frame's values) */
    movw    CUR_SP, %ax              /* old SP word == CUR_SP-4 (the near */
    subw    $4, %ax                  /*  call to the stub pushed 4 bytes)  */
    cmpw    %ax, %di                 /* SP */
    movl    $0xEE, %eax
    jne     1f
    cmpw    $0x0023, %dx             /* CS */
    jne     1f
    cmpw    $0x002B, %bp             /* SS */
    jne     1f
    movl    $0xAA, %eax
1:  movl    CUR_SLOT, %edi           /* (%edi) is DS-relative; (%ebp) would */
    movl    %eax, (%edi)             /* go through the boundary SS!        */
    iretw

/* ===================== CPL0 32-bit-gate handler ========================== *
 * Frame dwords: [0]=EIP [4]=CS [8]=EFLAGS [12]=ESP [16]=SS. */
    .code32
    .align 16
    .global h32
h32:
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    %esp, CUR_ESP
    movl    CUR_SP, %ecx               /* old ESP == CUR_SP-4 (the near call */
    subl    $4, %ecx                   /*  to the stub pushed 4 bytes)       */
    movl    $0xEE, %eax
    cmpl    $0x0023, 4(%esp)           /* CS */
    jne     1f
    cmpl    %ecx, 12(%esp)
    jne     1f
    cmpl    $0x002B, 16(%esp)          /* old SS */
    jne     1f
    movl    $0xAA, %eax
1:  movl    CUR_SLOT, %edi             /* (%edi) is DS-relative; (%ebp) would */
    movl    %eax, (%edi)               /* go through the boundary SS!        */
    iretl

/* ===================== CPL0 #SS handler for the R cases ================== *
 * Reached only on a broken build (a false #SS at an R-case iretw): exit
 * loudly with the case's CUR_RCODE. Runs on the boundary stack; touches no
 * stack itself. */
    .code32
    .align 16
    .global h_ss0
h_ss0:
    movw    $0x10, %ax
    movw    %ax, %ds
    movl    CUR_RCODE, %edi
    jmp     fail_exit

/* ===================== R-case 16-bit return stubs ======================== *
 * Each runs in CS 0x18 (16-bit, base 0xF0000) right after the case's iretw:
 * record the RETURNED FLAGS word (the restoration witness), then far-jump
 * back to the case's 32-bit rdone block. */
    .code16
    .align 16
    .global r16r0
r16r0:
    pushf
    pop     %ax
    movw    %ax, CUR_FLAGS
    .byte   0x66, 0xEA
    .long   _rdone0_off
    .word   0x0008
    .global r16r1
r16r1:
    pushf
    pop     %ax
    movw    %ax, CUR_FLAGS
    .byte   0x66, 0xEA
    .long   _rdone1_off
    .word   0x0008
    .global r16r2
r16r2:
    pushf
    pop     %ax
    movw    %ax, CUR_FLAGS
    .byte   0x66, 0xEA
    .long   _rdone2_off
    .word   0x0008
    .global r16r3
r16r3:
    pushf
    pop     %ax
    movw    %ax, CUR_FLAGS
    .byte   0x66, 0xEA
    .long   _rdone3_off
    .word   0x0008

/* ===================== the case table (16 x 6 dwords) ==================== *
 * {esp0, ss0_sel, stub_off, K, base, mask}. Even = at-bound (deliver),
 * odd = one slot-width past (#SS under enforcement). */
    .code32
    .align 16
case_table:
    .long 0x0000FFFD, 0x00000040, _i40_off, 10, 0x00030000, 0x0000FFFF /*  0 EU B0 word at   */
    .long 0x0000FFFF, 0x00000040, _i41_off, 10, 0x00030000, 0x0000FFFF /*  1 EU B0 word past */
    .long 0x0000FFFD, 0x00000048, _i40_off, 10, 0x00040000, 0xFFFFFFFF /*  2 EU B1 word at   */
    .long 0x0000FFFF, 0x00000048, _i41_off, 10, 0x00040000, 0xFFFFFFFF /*  3 EU B1 word past */
    .long 0x00000000, 0x00000050, _i40_off, 10, 0x00050000, 0x0000FFFF /*  4 ED B0 word at   */
    .long 0x0000FF02, 0x00000050, _i41_off, 10, 0x00050000, 0x0000FFFF /*  5 ED B0 word past */
    .long 0x00000000, 0x00000058, _i40_off, 10, 0x00060000, 0xFFFFFFFF /*  6 ED B1 word at   */
    .long 0x00000001, 0x00000058, _i41_off, 10, 0x00060000, 0xFFFFFFFF /*  7 ED B1 word past */
    .long 0x0000FFFD, 0x00000040, _i42_off, 20, 0x00030000, 0x0000FFFF /*  8 EU B0 dword at   */
    .long 0x00000001, 0x00000040, _i43_off, 20, 0x00030000, 0x0000FFFF /*  9 EU B0 dword past */
    .long 0x0000FFFD, 0x00000048, _i42_off, 20, 0x00040000, 0xFFFFFFFF /* 10 EU B1 dword at   */
    .long 0x00010001, 0x00000048, _i43_off, 20, 0x00040000, 0xFFFFFFFF /* 11 EU B1 dword past */
    .long 0x00000000, 0x00000050, _i42_off, 20, 0x00050000, 0x0000FFFF /* 12 ED B0 dword at   */
    .long 0x0000FF04, 0x00000050, _i43_off, 20, 0x00050000, 0x0000FFFF /* 13 ED B0 dword past */
    .long 0x00000000, 0x00000058, _i42_off, 20, 0x00060000, 0xFFFFFFFF /* 14 ED B1 dword at   */
    .long 0x00000001, 0x00000058, _i43_off, 20, 0x00060000, 0xFFFFFFFF /* 15 ED B1 dword past */

/* ===================== 16-bit reset stub @ 0xFFF0 ======================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off
    .word   0xF000
