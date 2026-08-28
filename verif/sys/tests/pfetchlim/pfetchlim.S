/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW1_Aug3 R2-H07: the DECODED-EXTENT instruction-fetch limit check.
 *
 * cs_fetch_fault (REVIEW2_aug2 H-05, pcslim) faults a fetch that STARTS past
 * CS.limit, but misses an instruction whose LATER bytes cross it. R2-H07 added
 * cs_extent_fault (rtl/core/core.sv, behind +define+VEN_SEG_ENFORCE): once the
 * decode provides (q_pc, q_len), the last byte of the instruction is checked
 * against CS.limit pre-issue, in both issue paths (S_PIPE fast path and
 * S_DECODE slow path), and #GP(0) is delivered stamped at q_pc BEFORE any of
 * the instruction's side effects. An instruction ending exactly AT the limit
 * (last byte offset == limit) is LEGAL and must not fault.
 *
 * QEMU is NOT a usable oracle for this: its translator checks only the
 * instruction's start address, so the straddling cases execute there. This is
 * a SELF-CHECKED witness gate against the SDM (like pseglim for C-06), and it
 * only exists in the +define+VEN_SEG_ENFORCE build.
 *
 * Layout: five one-case limited code segments, all limit 0x3F (valid offsets
 * 0x00..0x3F), each with a 7-byte far-jump "door" at offset 0 that returns to
 * the flat dispatcher, and one probe instruction placed so that:
 *
 *   case A (sel 0x18, entry 0x3E): 2-byte `jmp door` (EB C0), last byte AT
 *          offset 0x3F == the limit -> LEGAL, no fault in EITHER build
 *          (the at-limit false-positive tripwire).
 *   case B (sel 0x20, entry 0x3C): 5-byte `movl %eax,0x00030000` (A3 moffs32),
 *          bytes 0x3C..0x40, last byte 0x40 > limit -> #GP(0) pre-issue; the
 *          store must NOT reach the witness at 0x30000.
 *   case C1(sel 0x28, entry 0x3F): 2-byte `mov %al,(%ebx)` (88 07), bytes
 *          0x3F..0x40: starts AT the limit, ends past it -> #GP(0); the byte
 *          store must not touch the witness at 0x30004.
 *   case C2(sel 0x30, entry 0x3B): 6-byte `addl %eax,0x00030008` (01 05
 *          disp32), bytes 0x3B..0x40 -> #GP(0); the RMW must not touch the
 *          witness at 0x30008.
 *   case C3(sel 0x38, entry 0x3E): 2-byte `jmp +0` (EB 00) ending exactly at
 *          the limit, so the NEXT fetch starts at 0x40, PAST the limit ->
 *          #GP(0) from the OLDER first-byte check (cs_fetch_fault). Cross-check
 *          that the H-05 check still fires alongside the new extent check.
 *
 * Expected, ENFORCE build: exactly FOUR #GP(0)s (B, C1, C2, C3), each stamped
 * at the offending instruction; case A contributes none; the three witnesses
 * keep their seeds (no commit on fault); the #GP counter reads 4; the case-A
 * counter snapshot reads 0; isa-debug-exit status 133.
 *
 * Expected, DEFAULT build (no VEN_SEG_ENFORCE -- BOTH fetch checks are compiled
 * out, cs_fetch_fault included): no faults at all. Every probe EXECUTES: the
 * case-B/C1/C2 side effects clobber their witnesses (this is what proves the
 * witnesses discriminate), case C3's past-limit fetch runs its jump-back stub,
 * the counter stays 0 and the run exits with status 135 (0x43: "counter
 * wrong"), having taken ZERO faults. The gate only asserts "no vec=13 lines,
 * case A clean" on that build.
 *
 * The #GP handler is pseglim's pattern, extended: it also overwrites the saved
 * CS with the flat selector, so the IRET lands on door_flat in flat code
 * (returning into the 64-byte segment would be pointless -- the resume points
 * are all flat) and jumps indirectly through the per-case resume EIP the
 * mainline stashed at 0x704.
 *
 * NO PAGING: CR0.PG stays 0. Linear == physical throughout.
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
    movw    $0x7000, %sp        /* real-mode stack below the GDT copy */

    /* --- GDT at linear 0x0500: null + flat code + flat data; the five limited
     *     code descriptors (0x18..0x38) are built at runtime in pm_entry
     *     because their bases are link-time labels (R_386_16 truncation in a
     *     16-bit section -- pcslim's trick). --- */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000FFFF, 0x0508        /* 0x08 code32 flat DPL0 */
    movl    $0x00CF9A00, 0x050C
    movl    $0x0000FFFF, 0x0510        /* 0x10 data32 flat DPL0 */
    movl    $0x00CF9200, 0x0514

    movw    $0x003F, 0x0480            /* GDT limit = 8*8-1 (selectors up to 0x38) */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0                 /* CR0.PE=1, PG stays 0 */

    .byte   0x66, 0xEA                 /* ljmp ptr16:32 to the 32-bit flat code */
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
    movl    $0x00090000, %esp

    /* --- build the five limited code descriptors: base = the case stub label,
     *     limit 0x3F (G=0 so it is exact), access 0x9A, flags nibble 0x4. --- */
    movl    $caseA_stub, %ebx
    movl    $0x0518, %edi
    call    build_desc
    movl    $caseB_stub, %ebx
    movl    $0x0520, %edi
    call    build_desc
    movl    $caseC1_stub, %ebx
    movl    $0x0528, %edi
    call    build_desc
    movl    $caseC2_stub, %ebx
    movl    $0x0530, %edi
    call    build_desc
    movl    $caseC3_stub, %ebx
    movl    $0x0538, %edi
    call    build_desc

    /* --- IDT at 0x0600: vector 13 -> gp_handler through the FLAT selector
     *     0x08, so the handler is reachable whatever CS the fault was taken in.
     *     32-bit interrupt gate: low = sel<<16|off[15:0], high = off[31:16]|0x8E00. */
    movl    $0x00000600, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $gp_handler, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0600 + 13*8
    movl    $gp_handler, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax
    movl    %eax, 0x0600 + 13*8 + 4
    movw    $0x007F, 0x0490            /* IDT limit = 16*8-1 */
    movl    $0x00000600, 0x0492
    lidt    0x0490

    movl    $0, 0x00000700             /* #GP counter */
    movl    $0, 0x00000708             /* case-A counter snapshot (must stay 0) */

    /* ===== case A: instruction ending EXACTLY at the limit -- NO fault =====
     * Entry at offset 0x3E: EB C0 (jmp back to the door at offset 0). Last
     * byte at offset 0x3F == limit: legal. Runs identically in both builds. */
    movl    $caseA_ret, %eax
    movl    %eax, 0x00000704
    .byte   0xEA
    .long   0x3E
    .word   0x18
caseA_ret:
    movl    0x00000700, %eax
    movl    %eax, 0x00000708           /* snapshot: 0 iff case A did not fault */

    /* ===== case B: 5-byte straddling STORE -- #GP(0), no commit ===== */
    movl    $0x5EEDB005, 0x00030000    /* witness seed (flat) */
    movl    $caseB_ret, %eax
    movl    %eax, 0x00000704
    movl    $0xCAFEBABE, %eax          /* poison the store must NOT land */
    .byte   0xEA
    .long   0x3C
    .word   0x20
caseB_ret:

    /* ===== case C1: 2-byte straddling STORE, starts AT the limit ===== */
    movl    $0x5EEDC101, 0x00030004    /* witness seed (flat) */
    movl    $caseC1_ret, %eax
    movl    %eax, 0x00000704
    movl    $0x00030004, %ebx          /* store target for 88 07 */
    movb    $0xA5, %al                 /* poison byte */
    .byte   0xEA
    .long   0x3F
    .word   0x28
caseC1_ret:

    /* ===== case C2: 6-byte straddling RMW -- #GP(0), no commit ===== */
    movl    $0x5EEDC202, 0x00030008    /* witness seed (flat) */
    movl    $caseC2_ret, %eax
    movl    %eax, 0x00000704
    movl    $0x11111111, %eax          /* addend that must NOT be applied */
    .byte   0xEA
    .long   0x3B
    .word   0x30
caseC2_ret:

    /* ===== case C3: first-byte check cross-check (the H-05 case) =====
     * Entry at 0x3E: EB 00 ends exactly at the limit; the next fetch starts at
     * 0x40, PAST it -> #GP(0) from cs_fetch_fault, stamped at the fetch eip. */
    movl    $caseC3_ret, %eax
    movl    %eax, 0x00000704
    .byte   0xEA
    .long   0x3E
    .word   0x38
caseC3_ret:

    /* ============================ grade ================================== */
    movl    0x00000700, %ecx           /* #GP counter        -- want 4 */
    movl    0x00030000, %ebp           /* witness B          -- want 0x5EEDB005 */
    movl    0x00030004, %edi           /* witness C1         -- want 0x5EEDC101 */
    movl    0x00030008, %esi           /* witness C2         -- want 0x5EEDC202 */

    movl    0x00000708, %eax
    testl   %eax, %eax
    jnz     failA                      /* case A faulted: at-limit false positive */
    cmpl    $4, %ecx
    jne     failCnt
    cmpl    $0x5EEDB005, %ebp
    jne     failB                      /* the case-B store committed */
    cmpl    $0x5EEDC101, %edi
    jne     failC1                     /* the case-C1 store committed */
    cmpl    $0x5EEDC202, %esi
    jne     failC2                     /* the case-C2 RMW committed */
    movb    $0x42, %al                 /* 133: all four faults, no commits, A clean */
    jmp     do_exit
failA:
    movb    $0x47, %al                 /* 143 */
    jmp     do_exit
failCnt:
    movb    $0x43, %al                 /* 135: also the DEFAULT build's exit */
    jmp     do_exit
failB:
    movb    $0x44, %al                 /* 137 */
    jmp     do_exit
failC1:
    movb    $0x45, %al                 /* 139 */
    jmp     do_exit
failC2:
    movb    $0x46, %al                 /* 141 */
do_exit:
    movw    $0xF4, %dx
    outb    %al, %dx                   /* isa-debug-exit: status = (al<<1)|1 */
hang:
    hlt
    jmp     hang

    /* ============ descriptor builder: code32, base=%ebx, limit 0x3F =========
     *   low  = base[15:0]<<16 | 0x003F
     *   high = base[31:24] | 0x4<<20 | limit[19:16](0)<<16 | 0x9A<<8 | base[23:16] */
build_desc:
    movl    %ebx, %eax
    shll    $16, %eax
    movw    $0x003F, %ax
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFF000000, %eax
    movl    %ebx, %edx
    shrl    $16, %edx
    andl    $0x000000FF, %edx
    orl     %edx, %eax
    orl     $0x00409A00, %eax
    movl    %eax, 4(%edi)
    ret

    /* ========================= #GP handler ================================
     * Entered through the flat gate (CS=0x08). Frame: [esp]=err, [esp+4]=EIP,
     * [esp+8]=CS (the LIMITED selector), [esp+12]=EFLAGS. Count the fault, then
     * resume FLAT at door_flat, which dispatches through 0x704 -- the saved CS
     * must be rewritten too, or the IRET would land back in the 64-byte
     * segment at a flat-space EIP. */
    .global gp_handler
gp_handler:
    pushl   %eax
    movw    $0x10, %ax
    movw    %ax, %ds
    incl    0x00000700
    movl    $door_flat, %eax
    movl    %eax, 0x08(%esp)           /* saved EIP  <- door_flat */
    movl    $0x00000008, %eax
    movl    %eax, 0x0C(%esp)           /* saved CS   <- flat code selector */
    popl    %eax
    addl    $4, %esp                   /* discard the #GP error code */
    iret

    /* Flat dispatch target shared by the handler's IRET and every segment
     * door: jump to the per-case resume point the mainline stashed. */
    .global door_flat
door_flat:
    jmpl    *0x00000704

    /* ===================== the five 64-byte code segments ==================
     * Identical skeleton: a 7-byte far-jump door at offset 0 back to
     * door_flat, NOP padding, the probe instruction placed against the limit
     * boundary, and a jump-back stub past the boundary that only the DEFAULT
     * build (no enforcement) ever executes -- it is what lets the same image
     * run to its exit code with the checks compiled out. */
    .align  16
    .global caseA_stub
caseA_stub:
    .byte   0xEA
    .long   door_flat
    .word   0x08                       /* offset 0..6: the door */
    .fill   0x3E-7, 1, 0x90            /* NOP pad: offsets 0x07..0x3D */
    .byte   0xEB, 0xC0                 /* 0x3E: jmp -0x40 -> door. Last byte 0x3F == limit: LEGAL */

    .align  16
    .global caseB_stub
caseB_stub:
    .byte   0xEA
    .long   door_flat
    .word   0x08
    .fill   0x3C-7, 1, 0x90            /* offsets 0x07..0x3B */
    .byte   0xA3, 0x00, 0x00, 0x03, 0x00 /* 0x3C..0x40: movl %eax,0x00030000 -- STRADDLES */
    .byte   0xEB, 0xBD                 /* 0x41: default-build path back to the door */

    .align  16
    .global caseC1_stub
caseC1_stub:
    .byte   0xEA
    .long   door_flat
    .word   0x08
    .fill   0x3F-7, 1, 0x90            /* offsets 0x07..0x3E */
    .byte   0x88, 0x03                 /* 0x3F..0x40: mov %al,(%ebx) -- starts AT, ends PAST */
    .byte   0xEB, 0xBD                 /* 0x41: default-build path back to the door */

    .align  16
    .global caseC2_stub
caseC2_stub:
    .byte   0xEA
    .long   door_flat
    .word   0x08
    .fill   0x3B-7, 1, 0x90            /* offsets 0x07..0x3A */
    .byte   0x01, 0x05, 0x08, 0x00, 0x03, 0x00 /* 0x3B..0x40: addl %eax,0x00030008 -- STRADDLES */
    .byte   0xEB, 0xBD                 /* 0x41: default-build path back to the door */

    .align  16
    .global caseC3_stub
caseC3_stub:
    .byte   0xEA
    .long   door_flat
    .word   0x08
    .fill   0x3E-7, 1, 0x90            /* offsets 0x07..0x3D */
    .byte   0xEB, 0x00                 /* 0x3E..0x3F: jmp +0 -> next fetch at 0x40 (PAST limit) */
    .byte   0xEB, 0xBE                 /* 0x40: default-build path back to the door */

    /* ===================== 16-bit reset stub @ 0xFFF0 ====================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                       /* ljmp ptr16:16 */
    .word   _start16_off               /* offset within segment 0xF000 */
    .word   0xF000
