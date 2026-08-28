/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * prsmflush — REVIEW1_Aug4 R1-H02: executable invalidation must beat
 * CONSUMPTION, and now the full invalidation CONTRACT: the I-cache's valid
 * bits are observable through the +ven_icflushlog sim probe (rtl/mem/
 * icache.sv), so each case also proves WHERE the stale line sat (way 0 in one
 * subcase, way 1 in the other) and that the set's valid bits were zero one
 * clock after the flush edge, before the refill (the gate greps the probe
 * log; see run-prsmflush-gate.sh). Differential image (the B/I/D/C cases;
 * case A, the SMM/RSM scenario, lives in prsmflush_smm.S and is
 * witness-graded -- see manifest.json).
 *
 * The fix under test (rtl/core/core.sv): exec_issue_ok = !exec_flush_all now
 * gates every fast-serve decision (sfetch_fast / pipe_bytes_ok / v_bytes_ok /
 * uop_hit) and the S_PIPE FSM diverts to a post-edge refill
 * (core_fastpath.svh, pf_word<=0 on a flush cycle), and the canonical
 * I-cache's flush_all is wired to exec_flush_all (it was tied off, so a flush
 * could refill one way while the stale line stayed valid in the other --
 * duplicate valid tags in a set, hit priority deciding what executes).
 *
 * WAY-PLACEMENT MECHANICS (2-way; the lookup is linear-tagged, the per-line
 * physical tag is only a snoop key). Hit LRU touches do not move the
 * replacement victim here (the touch ports only confirm hits), so with a
 * fills-only age model the victim is always the way NOT filled most
 * recently. Every case therefore fills a same-set CONFLICT line (a lone
 * `ret` at target+0x1000: same set index addr[11:5], tag differs) BEFORE the
 * stale line, so the stale line is MRU at the flush edge and the post-flush
 * refill must land on the conflict line's way -- a flush that leaves the
 * stale way valid then produces two valid ways sharing one tag (the
 * ICACHE/DUP-TAG assertion) and hit priority serving stale bytes. Each
 * subcase gets a FRESH target line (its own page-table slot and frames), so
 * no subcase inherits a resident line from the previous one; the fill parity
 * then alternates the stale line's absolute way between consecutive
 * subcases, which is how each flush-source pair covers way 0 AND way 1 (the
 * probe log reports the actual placement; the gate requires both).
 *
 * THE CASES (all CPL0, paging ON):
 *   B1/B2 (CR3 reload): linear 0x400000 / 0x402000 remapped between frames
 *     whose stubs write distinguishable markers; `mov cr3` (full TLB flush
 *     -> tlb_flush_q -> exec_flush_all).
 *   I1/I2 (INVLPG): same shape at 0x404000 / 0x406000, flush source INVLPG
 *     (this core implements it as a conservative full TLB flush, which joins
 *     the same tlb_flush pulse).
 *   D1/D2 (INVD / WBINVD): no remap -- a CPU store would snoop-invalidate
 *     the line by its physical tag, which would test the snoop, not INVD.
 *     CONTRACT-ONLY cases at 0x408000 / 0x40A000: the bytes are unchanged,
 *     the probe log proves the line was valid at the cache_inv_go edge and
 *     empty one clock later, and the re-executed stub confirms the refetch.
 *   C1/C2 (A20 edge): with A20 ENABLED, fill the 0x101000 / 0x103000 line
 *     (OLD bytes), disable A20 via port 0x92 (a20_flush), fetch again: the
 *     physical fetch must alias onto 0x1000 / 0x3000 (NEW bytes). A20 is
 *     re-enabled after each subcase.
 *
 * CR0.CD note: CR0 resets with CD=1 (and NW=1), and with CD set no fetched
 * line is ever retained (fill_nocache) -- the very first instruction after
 * pm_entry clears CD+NW like any BIOS, or no line would ever be resident
 * and the contract would be unobservable.
 *
 * Witness slots: 0x2200 B1 fill (B_OLD), 0x2204 B1 final (B_NEW),
 *                0x2208 C1 final (C_NEW), 0x220C C1 fill (C_OLD),
 *                0x2210 B2 fill (B2_OLD), 0x2214 B2 final (B2_NEW),
 *                0x2218 I1 fill (I_OLD),  0x221C I1 final (I_NEW),
 *                0x2220 I2 fill (I2_OLD), 0x2224 I2 final (I2_NEW),
 *                0x2228 D1 mark (D_NEW),  0x222C D2 mark (D2_NEW),
 *                0x2230 C2 final (C2_NEW), 0x2234 C2 fill (C2_OLD).
 * In-guest self-checks (fail codes in edi: 0x11..0x1C), then the exit folds
 *   edi = 0x2204 (B_NEW),  esi = 0x2208 (C_NEW), ebx = 0x2200 (B_OLD),
 *   ebp = 0x220C (C_OLD),  ecx = 0x2224 (I2_NEW), edx = 0x600D600D.
 *
 * Memory plan: GDT @0x500, markers @0x2000..0x2240, PD @0x11000,
 * PT0 @0x12000 (identity 4 MiB), PT1 @0x13000 (linear [4,8) MiB window:
 * even slots are the case targets, odd slots the conflict rets), target
 * frames at phys 0x800000..0x80D000, conflict rets at 0x802000..0x80F000
 * and identity 0x100000/0x102000, A20 alias stubs at phys 0x1000/0x3000,
 * stack @0x7000. GNU-as; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
 */

.set GDT,  0x00000500
.set PD,   0x00011000
.set PT0,  0x00012000
.set PT1,  0x00013000

.set B_OLD,  0xB0010001
.set B_NEW,  0xB0020002
.set B2_OLD, 0xB0030003
.set B2_NEW, 0xB0040004
.set I_OLD,  0xB0050005
.set I_NEW,  0xB0060006
.set I2_OLD, 0xB0070007
.set I2_NEW, 0xB0080008
.set D_NEW,  0xB0090009
.set D2_NEW, 0xB00A000A
.set C_OLD,  0xC0010001
.set C_NEW,  0xC0020002
.set C2_OLD, 0xC0030003
.set C2_NEW, 0xC0040004

/* stub write slots, in subcase order */
.set S_B1,  0x00002204
.set S_B2,  0x00002214
.set S_I1,  0x0000221C
.set S_I2,  0x00002224
.set S_D1,  0x00002228
.set S_D2,  0x0000222C
.set S_C1,  0x00002208
.set S_C2,  0x00002230

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

    /* GDT @ 0x500: null, 0x08 code32 flat, 0x10 data32 flat */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000FFFF, 0x0508
    movl    $0x00CF9A00, 0x050C
    movl    $0x0000FFFF, 0x0510
    movl    $0x00CF9200, 0x0514
    movw    $0x0017, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
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
    movl    $0x00007000, %esp

    /* CR0 resets with CD=1 (and NW=1): with CD set no fetched line is ever
     * retained (fill_nocache) and the way-occupancy contract is unobservable.
     * Clear CD+NW like any BIOS does after POST. (The write also joins the
     * tlb_flush pulse -> an exec_flush_all with a not-yet-populated cache.) */
    movl    %cr0, %eax
    andl    $0x9FFFFFFF, %eax
    movl    %eax, %cr0

    /* zero the marker areas 0x2000..0x208F and 0x2200..0x223F */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $36, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00002200, %edi
    movl    $16, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    /* A20 ENABLED (port 0x92 bit 1): out of reset it is already on in both
     * oracles; write it explicitly so the pre-placement below never aliases.
     * Write-only toggles (no IN): an empty ISA slot reads 0x00 in QEMU but
     * 0xFF on the TB's io bus -- the read VALUE is environment, not
     * architecture, and would be a spurious diff. */
    movb    $0x02, %al
    outb    %al, $0x92

    /* pre-place the code stubs (paging still OFF -> linear == phys). Each
     * target line has an OLD frame and a NEW frame; conflicts are lone rets:
     *   B1: old 0x800000 new 0x801000   conflict ret 0x802000 (0x401000)
     *   B2: old 0x806000 new 0x807000   conflict ret 0x803000 (0x403000)
     *   I1: old 0x808000 new 0x809000   conflict ret 0x804000 (0x405000)
     *   I2: old 0x80A000 new 0x80B000   conflict ret 0x805000 (0x407000)
     *   D1:     0x80C000                conflict ret 0x80E000 (0x409000)
     *   D2:     0x80D000                conflict ret 0x80F000 (0x40B000)
     *   C1: old 0x101000  new 0x001000 (the A20-off alias), ret 0x100000
     *   C2: old 0x103000  new 0x003000 (the A20-off alias), ret 0x102000  */
    movl    $tpl_b1_old, %esi
    movl    $0x00800000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_b1_new, %esi
    movl    $0x00801000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_b2_old, %esi
    movl    $0x00806000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_b2_new, %esi
    movl    $0x00807000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_i1_old, %esi
    movl    $0x00808000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_i1_new, %esi
    movl    $0x00809000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_i2_old, %esi
    movl    $0x0080A000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_i2_new, %esi
    movl    $0x0080B000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_d1, %esi
    movl    $0x0080C000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_d2, %esi
    movl    $0x0080D000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_c1_old, %esi
    movl    $0x00101000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_c1_new, %esi
    movl    $0x00001000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_c2_old, %esi
    movl    $0x00103000, %edi
    movl    $11, %ecx
    rep movsb
    movl    $tpl_c2_new, %esi
    movl    $0x00003000, %edi
    movl    $11, %ecx
    rep movsb
    /* the six conflict-line rets + the two A20-case conflict rets */
    movb    $0xC3, 0x00802000
    movb    $0xC3, 0x00803000
    movb    $0xC3, 0x00804000
    movb    $0xC3, 0x00805000
    movb    $0xC3, 0x0080E000
    movb    $0xC3, 0x0080F000
    movb    $0xC3, 0x00100000
    movb    $0xC3, 0x00102000

    /* ---- page tables: PT0 = identity 4 MiB; PT1 = the [4,8) MiB window --- */
    movl    $PT0, %edi
    movl    $0x00000003, %eax           /* frame 0 | P|RW */
    movl    $1024, %ecx
1:  movl    %eax, (%edi)
    addl    $0x1000, %eax
    addl    $4, %edi
    loop    1b
    movl    $0x00800003, PT1 + 0x00     /* 0x400000 -> B1 old */
    movl    $0x00802003, PT1 + 0x04     /* 0x401000 -> B1 conflict ret */
    movl    $0x00806003, PT1 + 0x08     /* 0x402000 -> B2 old */
    movl    $0x00803003, PT1 + 0x0C     /* 0x403000 -> B2 conflict ret */
    movl    $0x00808003, PT1 + 0x10     /* 0x404000 -> I1 old */
    movl    $0x00804003, PT1 + 0x14     /* 0x405000 -> I1 conflict ret */
    movl    $0x0080A003, PT1 + 0x18     /* 0x406000 -> I2 old */
    movl    $0x00805003, PT1 + 0x1C     /* 0x407000 -> I2 conflict ret */
    movl    $0x0080C003, PT1 + 0x20     /* 0x408000 -> D1 */
    movl    $0x0080E003, PT1 + 0x24     /* 0x409000 -> D1 conflict ret */
    movl    $0x0080D003, PT1 + 0x28     /* 0x40A000 -> D2 */
    movl    $0x0080F003, PT1 + 0x2C     /* 0x40B000 -> D2 conflict ret */
    movl    $PT0 | 0x3, PD              /* PD[0] -> PT0 */
    movl    $PT1 | 0x3, PD + 4          /* PD[1] -> PT1 */

    movl    $PD, %eax
    movl    %eax, %cr3
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0                  /* CR0.PG = 1 */

    /* ==================== B1: CR3 reload ===================================
     * conflict first, then the stale fill (stale MRU at the flush; the
     * refill must land on the conflict's way), then remap + mov cr3. */
    call    0x00401000                  /* conflict fill (the lone ret) */
    call    0x00400000                  /* OLD: writes B_OLD to 0x2204, fills */
    movl    0x00002204, %eax
    movl    %eax, 0x00002200            /* fill proof */
    movl    $0x00801003, PT1 + 0x00     /* remap 0x400000 -> the NEW frame */
    movl    %cr3, %eax
    movl    %eax, %cr3                  /* full TLB flush -> exec_flush_all */
    call    0x00400000                  /* MUST execute NEW (B_NEW -> 0x2204) */

    /* ==================== B2: CR3 reload, fresh line ======================= */
    call    0x00403000                  /* conflict fill */
    call    0x00402000                  /* OLD: B2_OLD -> 0x2214 */
    movl    0x00002214, %eax
    movl    %eax, 0x00002210            /* fill proof */
    movl    $0x00807003, PT1 + 0x08     /* remap 0x402000 -> the NEW frame */
    movl    %cr3, %eax
    movl    %eax, %cr3
    call    0x00402000                  /* MUST execute NEW (B2_NEW -> 0x2214) */

    /* ==================== I1: INVLPG =======================================
     * Same shape, flush source INVLPG (a conservative full TLB flush here,
     * joining the same exec_flush_all pulse). */
    call    0x00405000                  /* conflict fill */
    call    0x00404000                  /* OLD: I_OLD -> 0x221C */
    movl    0x0000221C, %eax
    movl    %eax, 0x00002218            /* fill proof */
    movl    $0x00809003, PT1 + 0x10     /* remap 0x404000 -> the NEW frame */
    movl    $0x00404000, %eax
    invlpg  (%eax)                      /* TLB invalidate -> exec_flush_all */
    call    0x00404000                  /* MUST execute NEW (I_NEW -> 0x221C) */

    /* ==================== I2: INVLPG, fresh line =========================== */
    call    0x00407000                  /* conflict fill */
    call    0x00406000                  /* OLD: I2_OLD -> 0x2224 */
    movl    0x00002224, %eax
    movl    %eax, 0x00002220            /* fill proof */
    movl    $0x0080B003, PT1 + 0x18     /* remap 0x406000 -> the NEW frame */
    movl    $0x00406000, %eax
    invlpg  (%eax)
    call    0x00406000                  /* MUST execute NEW (I2_NEW -> 0x2224) */

    /* ==================== D1: INVD (contract-only) =========================
     * The backing bytes do not change -- a CPU store would snoop-invalidate
     * the line by its physical tag and test the wrong thing. The probe log
     * proves the line died at the INVD edge; the re-executed stub proves
     * the refetch. */
    call    0x00409000                  /* conflict fill */
    call    0x00408000                  /* D_NEW -> 0x2228, fills */
    invd                                /* cache_inv_go -> exec_flush_all */
    call    0x00408000                  /* refill, same bytes (D_NEW again) */

    /* ==================== D2: WBINVD (contract-only) ======================= */
    call    0x0040B000                  /* conflict fill */
    call    0x0040A000                  /* D2_NEW -> 0x222C, fills */
    wbinvd
    call    0x0040A000                  /* refill, same bytes */

    /* ==================== C1: A20 edge ===================================== */
    call    0x00100000                  /* conflict fill (identity-mapped ret) */
    call    0x00101000                  /* OLD: writes C_OLD to 0x2208, fills */
    movl    0x00002208, %eax
    movl    %eax, 0x0000220C            /* fill proof */
    movb    $0x00, %al                  /* A20 OFF -> a20_flush */
    outb    %al, $0x92
    call    0x00101000                  /* aliases to phys 0x1000: MUST be NEW */
    movb    $0x02, %al                  /* A20 back ON */
    outb    %al, $0x92

    /* ==================== C2: A20 edge, fresh line ========================= */
    call    0x00102000                  /* conflict fill */
    call    0x00103000                  /* OLD: writes C2_OLD to 0x2230, fills */
    movl    0x00002230, %eax
    movl    %eax, 0x00002234            /* fill proof */
    movb    $0x00, %al                  /* A20 OFF */
    outb    %al, $0x92
    call    0x00103000                  /* aliases to phys 0x3000: MUST be NEW */
    movb    $0x02, %al                  /* A20 back ON (courtesy) */
    outb    %al, $0x92

    /* ======================= self-checks + fold ============================ */
    cmpl    $B_OLD, 0x00002200
    je      1f
    movl    $0x11, %edi
    jmp     fail_exit
1:  cmpl    $B_NEW, 0x00002204
    je      2f
    movl    $0x12, %edi
    jmp     fail_exit
2:  cmpl    $C_OLD, 0x0000220C
    je      3f
    movl    $0x13, %edi
    jmp     fail_exit
3:  cmpl    $C_NEW, 0x00002208
    je      4f
    movl    $0x14, %edi
    jmp     fail_exit
4:  cmpl    $B2_OLD, 0x00002210
    je      5f
    movl    $0x15, %edi
    jmp     fail_exit
5:  cmpl    $B2_NEW, 0x00002214
    je      6f
    movl    $0x16, %edi
    jmp     fail_exit
6:  cmpl    $I_OLD, 0x00002218
    je      7f
    movl    $0x17, %edi
    jmp     fail_exit
7:  cmpl    $I_NEW, 0x0000221C
    je      8f
    movl    $0x18, %edi
    jmp     fail_exit
8:  cmpl    $I2_OLD, 0x00002220
    je      9f
    movl    $0x19, %edi
    jmp     fail_exit
9:  cmpl    $I2_NEW, 0x00002224
    je      10f
    movl    $0x1A, %edi
    jmp     fail_exit
10: cmpl    $D_NEW, 0x00002228
    je      11f
    movl    $0x1B, %edi
    jmp     fail_exit
11: cmpl    $D2_NEW, 0x0000222C
    je      12f
    movl    $0x1C, %edi
    jmp     fail_exit
12: cmpl    $C2_OLD, 0x00002234
    je      13f
    movl    $0x1D, %edi
    jmp     fail_exit
13: cmpl    $C2_NEW, 0x00002230
    je      14f
    movl    $0x1E, %edi
    jmp     fail_exit
14:
    movl    0x00002204, %edi            /* B_NEW */
    movl    0x00002208, %esi            /* C_NEW */
    movl    0x00002200, %ebx            /* B_OLD (fill proof) */
    movl    0x0000220C, %ebp            /* C_OLD (fill proof) */
    movl    0x00002224, %ecx            /* I2_NEW (last remap marker) */
    movl    $0x600D600D, %edx
    movl    $0x42, %eax
    movw    $0xF4, %dx                  /* edx -> 0x600D00F4 */
    outb    %al, %dx
9:  hlt
    jmp     9b

    .align 16
    .global fail_exit
fail_exit:                              /* edi = the failing check's code */
    movl    %edi, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

/* ===================== code-stub templates (11 bytes each) =============== *
 * movl $<VAL>, <slot> ; ret  ==  C7 05 <moffs32> <imm32>  C3               */
    .align 16
tpl_b1_old:
    .byte   0xC7, 0x05, 0x04, 0x22, 0x00, 0x00
    .long   B_OLD
    .byte   0xC3
tpl_b1_new:
    .byte   0xC7, 0x05, 0x04, 0x22, 0x00, 0x00
    .long   B_NEW
    .byte   0xC3
tpl_b2_old:
    .byte   0xC7, 0x05, 0x14, 0x22, 0x00, 0x00
    .long   B2_OLD
    .byte   0xC3
tpl_b2_new:
    .byte   0xC7, 0x05, 0x14, 0x22, 0x00, 0x00
    .long   B2_NEW
    .byte   0xC3
tpl_i1_old:
    .byte   0xC7, 0x05, 0x1C, 0x22, 0x00, 0x00
    .long   I_OLD
    .byte   0xC3
tpl_i1_new:
    .byte   0xC7, 0x05, 0x1C, 0x22, 0x00, 0x00
    .long   I_NEW
    .byte   0xC3
tpl_i2_old:
    .byte   0xC7, 0x05, 0x24, 0x22, 0x00, 0x00
    .long   I2_OLD
    .byte   0xC3
tpl_i2_new:
    .byte   0xC7, 0x05, 0x24, 0x22, 0x00, 0x00
    .long   I2_NEW
    .byte   0xC3
tpl_d1:
    .byte   0xC7, 0x05, 0x28, 0x22, 0x00, 0x00
    .long   D_NEW
    .byte   0xC3
tpl_d2:
    .byte   0xC7, 0x05, 0x2C, 0x22, 0x00, 0x00
    .long   D2_NEW
    .byte   0xC3
tpl_c1_old:
    .byte   0xC7, 0x05, 0x08, 0x22, 0x00, 0x00
    .long   C_OLD
    .byte   0xC3
tpl_c1_new:
    .byte   0xC7, 0x05, 0x08, 0x22, 0x00, 0x00
    .long   C_NEW
    .byte   0xC3
tpl_c2_old:
    .byte   0xC7, 0x05, 0x30, 0x22, 0x00, 0x00
    .long   C2_OLD
    .byte   0xC3
tpl_c2_new:
    .byte   0xC7, 0x05, 0x30, 0x22, 0x00, 0x00
    .long   C2_NEW
    .byte   0xC3

/* ===================== 16-bit reset stub @ 0xFFF0 ======================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* ljmp ptr16:16 */
    .word   _start16_off
    .word   0xF000
