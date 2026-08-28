/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW1_Aug3 R2-H05 (image 2 of 3) — 16-bit CALL GATES (type 0x4) and the
 * operand-size OPPOSITION cases. Differential vs the QEMU golden
 * (helper_lcall_protected, seg_helper.c:1556: push SIZE = the GATE width,
 * wrap mask = the stack's OWN SS.B, ESP commit = SET_ESP(sp, sp_mask)).
 *
 * The code segments for the gate legs are based at 0xF0000 (the image), so
 * every EIP involved in a 16-bit gate frame is a small OFFSET that survives
 * the word-wide IP push / the 16-bit gate offset field (pintr16's trick).
 *
 *   case 1: SAME-privilege 16-bit gate, 32-bit caller (CPL0, code0f). The
 *           operand size (32) is deliberately OPPOSITE the gate width (16):
 *           the return frame must be WORDS [IP, CS], ESP -= 4, and the
 *           caller's two dword params sit right above it (NO param copy on a
 *           same-privilege transfer). The callee returns with a 16-bit
 *           `lret $8` (0x66 CA), discarding the params.
 *   case 4: 32-bit gate (type 0xC) from a 16-bit caller (CPL0, code16 D=0):
 *           the OTHER opposition direction. The 16-bit `lcall ptr16:16`
 *           through the 32-bit gate must push the return frame as DWORDS
 *           [EIP, CS] (gate width, not the caller's operand size); the
 *           32-bit callee returns with a plain 32-bit lret.
 *   case 3: CROSS-privilege 16-bit gate (CPL3 -> CPL0), param count 4, new
 *           stack a 16-bit (B=0) segment with base 0. Word-unit frame
 *           [IP, CS, p0..p3, SP, SS]; param words 0xB500|i copied off the
 *           old (32-bit) stack in word units; ESP commit = espN - (8+2n)
 *           (old ESP upper bits are 0, so SET_ESP masking is a no-op here);
 *           the callee returns with a 16-bit cross-privilege `lret $8`
 *           (pops SP/SS words; outer ESP zero-extended, H-02 semantics).
 *   case 2: CROSS-privilege 16-bit gate, param count 1, new stack 16-bit
 *           (B=0) with base 0x70000, old ESP = 0x0007F100 (upper 16 bits
 *           NONZERO). QEMU's SET_ESP(sp, sp_mask) commits
 *           ESP = (old_ESP & 0xFFFF0000) | ((espN - fsz) & 0xFFFF)
 *              = 0x000781F6,
 *           i.e. the upper 16 bits LEAK from the old ESP -- while the pushes
 *           physically went to ssp + (sp & 0xFFFF) = 0x781F6... This is the
 *           genuine SET_ESP quirk; the committed SP cannot address the frame
 *           (and would #SS past the 64K limit), so the callee verifies the
 *           frame through FLAT DS absolute reads at 0x781Fx and EXITS
 *           (CPL0), with esp=0x000781F6 as the final-record witness.
 *
 * PRE-FIX BEHAVIOUR (negative control, HEAD build): lc_gate/lc_callw did not
 * exist, so case 1 pushed a DWORD frame through the 16-bit gate (the 0x66
 * lret then pops a bogus CS -> #GP cascade), case 4 pushed a WORD frame
 * through the 32-bit gate (mirror-image corruption), and cases 3/2 (param
 * count != 0, cross-privilege) hit the 0xDA loud-HALT.
 *
 * Memory plan (NO paging):
 *   GDT @ 0x500 (15 entries): 0x08 code0 / 0x10 data0 / 0x20 data3 (flat),
 *     0x28 TSS (base 0x4000), 0x30 ss16 (B=0 base 0x70000 lim 0xFFFF),
 *     0x38 ss16b (B=0 base 0 lim 0xFFFF), 0x40 code16 (D=0 base 0xF0000),
 *     0x48 gate16 pcount4 -> code0f:c3h (DPL3), 0x50 gate16 pcount1 ->
 *     code0f:c2h (DPL3), 0x58 code3f (D=1 DPL3 base 0xF0000),
 *     0x60 code0f (D=1 DPL0 base 0xF0000), 0x68 gate16 pcount0 -> c1h (DPL0),
 *     0x70 gate32 pcount0 -> c4h (DPL0)
 *   IDT @ 0x1000: #GP(13) -> gp_catch (diagnostic: exits with sentinels)
 *   markers @ 0x2000; TSS @ 0x4000; ring0 stack 0x7000
 *
 * GNU-as syntax; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ss
    movw    %ax, %ds
    movw    $0x7000, %sp

    /* GDT at 0x0500, 13 entries (limit 0x67). */
    movl    $0x00000000, 0x0500        /* 0x00 null */
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508        /* 0x08 code0 flat DPL0 */
    movl    $0x00cf9a00, 0x050c
    movl    $0x0000ffff, 0x0510        /* 0x10 data0 flat DPL0 */
    movl    $0x00cf9200, 0x0514
    movl    $0x00000000, 0x0518        /* 0x18 (unused) */
    movl    $0x00000000, 0x051c
    movl    $0x0000ffff, 0x0520        /* 0x20 data3 flat DPL3 -> 0x23 */
    movl    $0x00cff200, 0x0524
    movl    $0x40000067, 0x0528        /* 0x28 TSS32: base 0x4000, limit 0x67 */
    movl    $0x00008900, 0x052c
    movl    $0x0000ffff, 0x0530        /* 0x30 ss16:  base 0x70000, B=0, RW DPL0 */
    movl    $0x00009207, 0x0534
    movl    $0x0000ffff, 0x0538        /* 0x38 ss16b: base 0, B=0, RW DPL0 */
    movl    $0x00009200, 0x053c
    movl    $0x0000ffff, 0x0540        /* 0x40 code16: D=0, base 0xF0000, lim 0xFFFF */
    movl    $0x00009a0f, 0x0544
    /* 0x48 / 0x50 / 0x68 / 0x70 gates built in pm_entry (need label offsets) */
    movl    $0x0000ffff, 0x0558        /* 0x58 code3f: D=1 DPL3, base 0xF0000 */
    movl    $0x0040fa0f, 0x055c
    movl    $0x0000ffff, 0x0560        /* 0x60 code0f: D=1 DPL0, base 0xF0000 */
    movl    $0x00409a0f, 0x0564

    movw    $0x0077, 0x0480            /* 15 entries (0x00..0x70) */
    movl    $0x00000500, 0x0482
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
    movl    $0x00007000, %esp

    /* ---- zero the marker area 0x2000..0x2080 ---- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $34, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0xBAD0160D, 0x000020F0    /* "gp_catch ran" sentinel */

    /* ---- IDT @ 0x1000: zero; #GP(13) -> gp_catch (diagnostic) ------------- */
    movl    $0x00001000, %edi
    xorl    %eax, %eax
    movl    $512, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $gp_catch, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1068
    movl    $gp_catch, %eax
    andl    $0xffff0000, %eax
    orl     $0x00008f00, %eax
    movl    %eax, 0x106c
    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- the four call gates ---------------------------------------------
     * low  = {target sel}<<16 | off[15:0];  high = off[31:16] | access | pcount
     * 16-bit gate DPL3 access = 0xE4; 16-bit DPL0 = 0x84; 32-bit DPL0 = 0x8C.
     * Gate offsets are OFFSETS from the code0f base (0xF0000) -- 16-bit
     * gates carry only off[15:0], which is why the target segments are based
     * at the image.                                                            */
    movl    $c1h, %eax                 /* 0x68: 16-bit gate, pcount 0, DPL0 */
    subl    $0x000F0000, %eax
    movzwl  %ax, %eax
    orl     $0x00600000, %eax
    movl    %eax, 0x0568
    movl    $0x00008400, 0x056c

    movl    $c4h, %eax                 /* 0x70: 32-bit gate, pcount 0, DPL0 */
    subl    $0x000F0000, %eax
    movzwl  %ax, %eax
    orl     $0x00600000, %eax
    movl    %eax, 0x0570
    movl    $0x00008c00, 0x0574

    movl    $c3h, %eax                 /* 0x48: 16-bit gate, pcount 4, DPL3 */
    subl    $0x000F0000, %eax
    movzwl  %ax, %eax
    orl     $0x00600000, %eax
    movl    %eax, 0x0548
    movl    $0x0000e404, 0x054c

    movl    $c2h, %eax                 /* 0x50: 16-bit gate, pcount 1, DPL3 */
    subl    $0x000F0000, %eax
    movzwl  %ax, %eax
    orl     $0x00600000, %eax
    movl    %eax, 0x0550
    movl    $0x0000e401, 0x0554

    /* ---- TSS at 0x4000 (SS0:ESP0 for case 3; case 2 rewrites it) --------- */
    movl    $0x00004000, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $0x00008400, 0x00004004    /* ESP0 (case 3) */
    movl    $0x00000038, 0x00004008    /* SS0 = ss16b (case 3) */
    movw    $0x0068,     0x00004066
    movw    $0x0028, %ax
    ltr     %ax

    /* ================= case 1: same-priv 16-bit gate, 32-bit caller ======= */
    .byte   0x9A                       /* lcall ptr16:32 to caller1 (code0f) */
    .long   caller1 - 0xF0000
    .word   0x0060

    /* ================= case 4: 32-bit gate, 16-bit caller ================= */
    .byte   0x9A                       /* lcall ptr16:32 to caller16 (code16) */
    .long   caller16 - 0xF0000
    .word   0x0040
    movl    $0x16000004, 0x00002024    /* "case 4 returned to main" */

    /* ---- down to CPL3 (outer RETF) into code3f for cases 3 and 2 --------- */
    pushl   $0x00000023                /* SS  = data3 */
    pushl   $0x0000F800                /* ESP = user stack (reset per case) */
    pushl   $0x0000005B                /* CS  = code3f | RPL3 */
    pushl   $(r3_16 - 0xF0000)         /* EIP = offset in code3f */
    lret

    /* ==================== case-1 caller / callee (CPL0) =================== */
    .align 16
    .global caller1
caller1:                               /* runs in code0f (EIP = small offset) */
    movl    %esp, %ebp                 /* entry ESP (restored check) */
    pushl   $0xC6000000                /* [esp+4] at the lcall */
    pushl   $0xC6000001                /* [esp]   at the lcall */
    .byte   0x9A                       /* 32-bit-operand lcall through a 16-BIT gate */
    .long   0
    .word   0x0068
caller1_back:
    cmpl    %ebp, %esp                 /* c1h's `0x66 lret $8` popped both params */
    jne     1f
    movl    $0x16000001, 0x00002020
1:  lret                               /* 32-bit: pops main's dword frame */

    .align 16
    .global c1h
c1h:                                   /* same-priv WORD frame: [0]=IP [2]=CS */
    movzwl  0(%esp), %eax
    movl    %eax, 0x00002000           /* ret IP word (want caller1_back off) */
    movzwl  2(%esp), %eax
    movl    %eax, 0x00002004           /* ret CS word (want 0x0060) */
    movl    4(%esp), %eax
    movl    %eax, 0x00002008           /* caller param (want 0xC6000001) */
    movl    8(%esp), %eax
    movl    %eax, 0x0000200C           /* caller param (want 0xC6000000) */
    movl    %esp, %eax
    movl    %eax, 0x00002010           /* callee ESP (entry ESP - 4) */
    .byte   0x66, 0xCA                 /* 16-bit lret $8: pop IP/CS words, +8 */
    .word   8

    /* ==================== case-4 caller / callee (CPL0) =================== */
    .align 16
    .code16
    .global caller16
caller16:                              /* runs in code16 (D=0): 16-bit operand */
    .byte   0x9A                       /* lcall ptr16:16 through a 32-BIT gate */
    .word   0
    .word   0x0070
caller16_back:
    .byte   0x66, 0xCB                 /* 32-bit lret: pops main's dword frame */
    .code32

    .align 16
    .global c4h
c4h:                                   /* gate-width DWORD frame on the SAME stack */
    movl    0(%esp), %eax
    movl    %eax, 0x00002014           /* ret EIP dword (want caller16_back off) */
    movl    4(%esp), %eax
    movl    %eax, 0x00002018           /* ret CS dword (want 0x00000040) */
    movl    %esp, %eax
    movl    %eax, 0x0000201C           /* callee ESP (entry ESP - 8) */
    lret                               /* 32-bit lret back into code16 */

    /* ==================== ring 3: cases 3 and 2 ========================== */
    .align 16
    .global r3_16
r3_16:                                 /* runs in code3f (base 0xF0000) */
    movw    $0x23, %ax                 /* the outer RETF nulled DS */
    movw    %ax, %ds

    /* ---- case 3: cross-priv 16-bit gate, pcount 4, consistent 16-bit stack */
    movw    $0xB500, 0x0000F0F8        /* param words at 0xF0F8..0xF0FE */
    movw    $0xB501, 0x0000F0FA
    movw    $0xB502, 0x0000F0FC
    movw    $0xB503, 0x0000F0FE
    movl    $0x0000F0F8, %esp
    .byte   0x9A                       /* 32-bit-operand lcall through gate 0x48 */
    .long   0
    .word   0x004B
case3_back:
    /* QEMU applies the imm16 twice on a cross-privilege RETF: the restored
     * outer ESP = popped SP word (zero-extended 0xF0F8) + 8 = 0xF100. */
    movl    %esp, %eax
    cmpl    $0x0000F100, %eax
    jne     1f
    movl    $0x16000003, 0x00002044
1:
    /* ---- case 2: cross-priv 16-bit gate, pcount 1, SET_ESP upper-16 quirk
     * Rewrite TSS.SS0:ESP0 (no paging: ring 3 may store anywhere) to the
     * 16-bit stack based at 0x70000, and run with old ESP = 0x0007F100 so
     * the committed ESP keeps the old upper 16 bits (0x0007xxxx).          */
    movl    $0x00008200, 0x00004004    /* ESP0 */
    movl    $0x00000030, 0x00004008    /* SS0 = ss16 (base 0x70000) */
    movw    $0xB501, 0x0007F100        /* the one param word */
    movl    $0x0007F100, %esp
    .byte   0x9A                       /* lcall through gate 0x50 -> c2h EXITS */
    .long   0
    .word   0x0053
9:  jmp     9b                         /* unreachable (c2h exits) */

    /* ---- case-3 callee (CPL0, code0f): word frame at 0x83F0 --------------
     * [0]=IP [2]=CS(0x5B) [4..10]=p0..p3 words [12]=SP(0xF0F8) [14]=SS(0x23) */
    .align 16
    .global c3h
c3h:
    movzwl  0(%esp), %eax
    movl    %eax, 0x00002028           /* ret IP word (want case3_back off) */
    movzwl  2(%esp), %eax
    movl    %eax, 0x0000202C           /* ret CS word (want 0x005B) */
    movzwl  4(%esp), %eax
    movl    %eax, 0x00002030           /* param[0] (want 0xB500) */
    movzwl  10(%esp), %eax
    movl    %eax, 0x00002034           /* param[3] (want 0xB503) */
    movzwl  12(%esp), %eax
    movl    %eax, 0x00002038           /* old SP word (want 0xF0F8) */
    movzwl  14(%esp), %eax
    movl    %eax, 0x0000203C           /* old SS word (want 0x0023) */
    movl    %esp, %eax
    movl    %eax, 0x00002040           /* new ESP (want 0x000083F0) */
    .byte   0x66, 0xCA                 /* 16-bit cross-priv lret $8 */
    .word   8

    /* ---- case-2 callee (CPL0, code0f): frame pushed at 0x781F6..0x781FE,
     * but the committed ESP = 0x000781F6 (old ESP's upper 16 leaked through
     * SET_ESP) CANNOT address it -- verify via FLAT DS absolute reads and
     * exit. NO SS-relative access is legal here (offset > 64K limit).      */
    .align 16
    .global c2h
c2h:
    movzwl  0x000781F6, %eax
    movl    %eax, 0x00002048           /* ret IP word */
    movzwl  0x000781F8, %eax
    movl    %eax, 0x0000204C           /* ret CS word (want 0x005B) */
    movzwl  0x000781FA, %eax
    movl    %eax, 0x00002050           /* param word (want 0xB501) */
    movzwl  0x000781FC, %eax
    movl    %eax, 0x00002054           /* old SP word (want 0xF100) */
    movzwl  0x000781FE, %eax
    movl    %eax, 0x00002058           /* old SS word (want 0x0023) */
    movl    %esp, %eax
    movl    %eax, 0x0000205C           /* committed ESP (want 0x000781F6) */
    movw    %ss, %ax
    movzwl  %ax, %eax
    movl    %eax, 0x00002060           /* new SS (want 0x0030) */
    /* exit at CPL0: pull the witnesses into the GPRs */
    movl    0x0000205C, %edi           /* SET_ESP quirk (want 0x000781F6) */
    movl    0x00002030, %esi           /* case3 param[0] (want 0xB500) */
    movl    0x00002044, %ecx           /* case3 return flag (want 0x16000003) */
    movl    0x00002018, %ebp           /* case4 CS dword (want 0x40) */
    movl    0x00002020, %ebx           /* case1 ESP flag (want 0x16000001) */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b

    /* ===================== diagnostic #GP catcher ========================= */
    .align 16
    .global gp_catch
gp_catch:
    movl    (%esp), %eax               /* #GP error code */
    movl    %eax, 0x000020F0
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
