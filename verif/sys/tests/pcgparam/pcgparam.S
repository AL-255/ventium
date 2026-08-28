/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW1_Aug3 R2-H05 (image 1 of 3) — 32-bit CALL GATES with a PARAMETER
 * COPY, cross-privilege (CPL3 -> CPL0) and same-privilege. Differential vs
 * the QEMU golden (helper_lcall_protected, seg_helper.c:1556):
 *
 *   (a) 32-bit gate (type 0xC), param count 0  -- the control: 4-dword frame
 *       [retEIP, retCS, old ESP, old SS], new ESP = TSS.ESP0 - 16.
 *   (b) 32-bit gate, param count 1  -- one dword copied from the OLD stack.
 *   (c) 32-bit gate, param count 31 -- the MAXIMUM count: 31 dwords copied,
 *       distinctive values 0xA5000000|i, order checked exhaustively by the
 *       callee (param[i] must sit at 8+4i(%esp): QEMU pushes the
 *       highest-address param FIRST, so param[0] ends up closest to the
 *       return frame). Frame = 16 + 4*31 = 140 bytes.
 *   (d) SAME-privilege 32-bit gate (CPL3 -> code3): the return frame is
 *       pushed in the GATE's width on the SAME stack and NO parameter copy
 *       happens -- the callee reads the caller's two dwords directly above
 *       the 2-slot return frame.
 *   Each cross-privilege callee returns with RETF imm16 = 4*n (parameter
 *   discard on the inner stack); the caller proves its own ESP is restored
 *   to the value it had at the lcall (0x5000) after popping its locals.
 *
 * The oracle semantics pinned here (QEMU helper_lcall_protected):
 *   push SIZE = the GATE width (type 0xC -> dword), never the caller's
 *   operand size; the wrap mask is the relevant stack's OWN SS.B; the param
 *   source is old_ssp + ((ESP + i*4) & old_sp_mask); the new ESP commits as
 *   espN - (16 + 4n) (32-bit new stack here, so no masking quirk -- pcg16
 *   covers the 16-bit SET_ESP semantics).
 *
 * PRE-FIX BEHAVIOUR (negative control, HEAD build): a cross-privilege call
 * gate with param count != 0 hit the 0xDA loud-HALT ("param copy not
 * implemented"), so cases (b)/(c) froze the machine mid-stream; the same-
 * privilege case used the caller's operand size for the frame (lc_callw did
 * not exist), which is invisible here (32-bit caller == 32-bit gate) but is
 * graded in pcg16.
 *
 * Memory plan (NO paging -- the param-copy semantics are paging-independent;
 * the paged forms live in pcgpg):
 *   GDT  @ 0x00000500   null + code0 0x08 + data0 0x10 + code3 0x18 + data3 0x20
 *                       + TSS 0x28 + gate_p0 0x30 + gate_p1 0x38 + gate_p31 0x40
 *                       + gate_same 0x48 (all 32-bit call gates, DPL 3)
 *   IDT  @ 0x00001000   gate 13 (#GP) -> gp_catch, gate 14 (#PF) -> pf_catch
 *                       (diagnostic only: an unexpected fault exits with the
 *                       0xBAD0FF0x markers intact -> the differential goes red)
 *   markers @ 0x00002000
 *   TSS  @ 0x00004000   SS0=0x10 ESP0=0x9000
 *   ring0 boot stack 0x7000, ring3 stack 0x5000, TSS0 stack top 0x9000
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

    /* GDT at 0x0500 (10 entries, limit 0x4F):
     *   0x08 code0 nonconforming (0x9A)   0x10 data0 (0x92)
     *   0x18 code3 nonconforming (0xFA)   0x20 data3 (0xF2)
     *   0x28 TSS32 (built below)          0x30 gate32 pcount0  -> h0  (code0)
     *   0x38 gate32 pcount1  -> h1        0x40 gate32 pcount31 -> h31
     *   0x48 gate32 pcount0  -> h3same (code3: SAME privilege)          */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508        /* 0x08 code32 DPL0 nonconforming */
    movl    $0x00cf9a00, 0x050c
    movl    $0x0000ffff, 0x0510        /* 0x10 data32 DPL0 */
    movl    $0x00cf9200, 0x0514
    movl    $0x0000ffff, 0x0518        /* 0x18 code32 DPL3 -> 0x1B */
    movl    $0x00cffa00, 0x051c
    movl    $0x0000ffff, 0x0520        /* 0x20 data32 DPL3 -> 0x23 */
    movl    $0x00cff200, 0x0524
    movl    $0x40000067, 0x0528        /* 0x28 TSS32: base 0x4000, limit 0x67 */
    movl    $0x00008900, 0x052c

    movw    $0x004F, 0x0480            /* GDT limit = 10*8-1 (gates reach 0x48) */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                 /* opsize-32 ljmp ptr16:32 */
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

    /* ---- zero the marker area 0x2000..0x2100 ---- */
    movl    $0x00002000, %edi
    xorl    %eax, %eax
    movl    $64, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    /* "fault catcher ran" sentinels: any unexpected #GP/#PF overwrites these */
    movl    $0xBAD0FF0D, 0x000020F0
    movl    $0xBAD0FF0E, 0x000020F4

    /* ---- IDT @ 0x1000: zero all gates; #GP/#PF -> diagnostic catchers ---- */
    movl    $0x00001000, %edi
    xorl    %eax, %eax
    movl    $512, %ecx
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    /* IDT[13] @ 0x1068 -> gp_catch (trap gate 0x8F DPL0, CS=0x08: a fault at
     * CPL3 switches to the TSS stack and exits from CPL0) */
    movl    $gp_catch, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1068
    movl    $gp_catch, %eax
    andl    $0xffff0000, %eax
    orl    $0x00008f00, %eax
    movl    %eax, 0x106c
    /* IDT[14] @ 0x1070 -> pf_catch */
    movl    $pf_catch, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x1070
    movl    $pf_catch, %eax
    andl    $0xffff0000, %eax
    orl    $0x00008f00, %eax
    movl    %eax, 0x1074
    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* ---- the four 32-bit call gates (type 0xC, DPL 3) ----------------------
     * low  = {target sel}<<16 | off[15:0]
     * high = off[31:16] | P|DPL3|0xC (0xEC00) | param count                  */
    movl    $h0, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0530               /* gate 0x30 -> h0, pcount 0 */
    movl    $h0, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ec00, %eax
    movl    %eax, 0x0534

    movl    $h1, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0538               /* gate 0x38 -> h1, pcount 1 */
    movl    $h1, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ec01, %eax
    movl    %eax, 0x053c

    movl    $h31, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0540               /* gate 0x40 -> h31, pcount 31 */
    movl    $h31, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ec1f, %eax
    movl    %eax, 0x0544

    movl    $h3same, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00180000, %eax          /* target = code3 (SAME priv) */
    movl    %eax, 0x0548               /* gate 0x48 -> h3same, pcount 0 */
    movl    $h3same, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ec00, %eax
    movl    %eax, 0x054c

    /* ---- TSS at 0x4000: SS0=0x10, ESP0=0x9000, empty I/O map ---- */
    movl    $0x00004000, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
    rep stosl
    movl    $0x00009000, 0x00004004    /* ESP0 */
    movl    $0x00000010, 0x00004008    /* SS0  */
    movw    $0x0068,     0x00004066

    movw    $0x0028, %ax
    ltr     %ax

    /* IOPL = 3 so the ring-3 legs may drive port 0xF4. */
    pushfl
    orl     $0x00003000, (%esp)
    popfl

    /* ---- out to ring 3 via the OUTER RETF (pjmpgate's mechanism) --------- */
    pushl   $0x00000023                /* SS  = ring-3 data, RPL 3 */
    pushl   $0x00005000                /* ESP = the ring-3 stack */
    pushl   $0x0000001B                /* CS  = ring-3 code, RPL 3 */
    pushl   $r3_entry                  /* EIP */
    lret

    /* ============================ ring 3 ================================== */
    .global r3_entry
r3_entry:
    /* The outer RETF NULLED DS (DPL 0 < CPL 3) -- reload before any data. */
    movw    $0x23, %ax
    movw    %ax, %ds

    /* ---- case (a): 32-bit gate, param count 0 (the control) -------------- */
    movl    $0x00005000, %esp
    .byte   0x9A
    .long   0
    .word   0x0033                     /* gate 0x30 | RPL 3 */
after0:
    movl    %esp, %eax                 /* RETF restored ESP to the lcall value */
    cmpl    $0x00005000, %eax
    jne     1f
    movl    $0xE5900000, 0x00002058
1:

    /* ---- case (b): 32-bit gate, param count 1 ---------------------------- */
    movl    $0x00005000, %esp
    pushl   $0xA5000000                /* param[0] at 0x4FFC */
    .byte   0x9A
    .long   0
    .word   0x003B                     /* gate 0x38 | RPL 3 */
after1:
    /* QEMU helper_ret_protected applies the imm16 TWICE on a cross-privilege
     * RETF: once to the inner SP before the outer ESP/SS pops (skipping the
     * copied params on the inner stack), and again to the RESTORED outer ESP.
     * So h1's `lret $4` already returns with ESP = 0x4FFC + 4 = 0x5000 -- the
     * caller's own param dword is discarded by the callee's imm16. */
    movl    %esp, %eax
    cmpl    $0x00005000, %eax
    jne     1f
    movl    $0xE5900001, 0x00002034
1:

    /* ---- case (c): 32-bit gate, param count 31 (the maximum) --------------
     * Push param[30] first ... param[0] last, so param[i] sits at ESP+4i at
     * the lcall: param[i] = 0xA5000000|i.                                  */
    movl    $0x00005000, %esp
    movl    $31, %ecx
    movl    $30, %ebx
1:  movl    %ebx, %eax
    orl     $0xA5000000, %eax
    pushl   %eax
    decl    %ebx
    loop    1b
    .byte   0x9A
    .long   0
    .word   0x0043                     /* gate 0x40 | RPL 3 */
after31:
    movl    %esp, %eax                 /* 0x4F84 + 124 = 0x5000 (see after1) */
    cmpl    $0x00005000, %eax
    jne     1f
    movl    $0xE590001F, 0x00002038
1:

    /* ---- case (d): SAME-privilege 32-bit gate -> code3, NO param copy ----
     * The two dwords stay on the SAME stack, directly above the 2-slot
     * return frame the gate pushes (dword width, from the GATE type).      */
    movl    $0x00005000, %esp
    pushl   $0xC6000000                /* [esp+4] at the lcall */
    pushl   $0xC6000001                /* [esp]   at the lcall */
    .byte   0x9A
    .long   0
    .word   0x004B                     /* gate 0x48 | RPL 3 */
aftersame:
    movl    %esp, %eax                 /* h3same's lret $8 popped both params */
    cmpl    $0x00005000, %eax
    jne     1f
    movl    $0xE5905A4E, 0x0000204C
1:

    /* ---- exit: pull the witnesses into the GPRs (eax/dx die at the out) -- */
    movl    0x00002020, %edi           /* h31 mismatch count (want 0) */
    movl    0x00002010, %esi           /* h1 param[0] (want 0xA5000000) */
    movl    0x00002024, %ecx           /* h31 old ESP (want 0x00004F84) */
    movl    0x00002044, %ebp           /* h3same frame CS (want 0x1B) */
    movl    0x0000204C, %ebx           /* same-priv ESP flag (want 0xE5905A4E) */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                   /* CPL==IOPL==3 */
9:  jmp     9b

    /* ===================== CPL0 callees (cross-privilege) =================
     * 32-bit gate frame with param count n (new ESP = 0x9000 - (16+4n)):
     *   0(%esp) = return EIP        4(%esp) = return CS (0x1B)
     *   8+4i(%esp) = param[i]  (param[0] closest to the return frame:
     *                           the highest-address param is pushed first)
     *   8+4n(%esp) = old ESP        12+4n(%esp) = old SS (0x23)             */
    .align 16
    .global h0
h0:
    movl    8(%esp), %eax              /* old ESP (want 0x5000) */
    movl    %eax, 0x00002000
    movl    12(%esp), %eax             /* old SS (want 0x23) */
    movl    %eax, 0x00002004
    movw    %ss, %ax
    movzwl  %ax, %eax
    movl    %eax, 0x00002008           /* new SS (want 0x10) */
    movl    %esp, %eax
    movl    %eax, 0x0000200C           /* new ESP (want 0x8FF0) */
    movl    4(%esp), %eax
    movl    %eax, 0x00002050           /* return CS (want 0x1B) */
    movl    0(%esp), %eax
    movl    %eax, 0x00002054           /* return EIP (want after0) */
    lret    $0

    .align 16
    .global h1
h1:
    movl    8(%esp), %eax              /* param[0] (want 0xA5000000) */
    movl    %eax, 0x00002010
    movl    12(%esp), %eax             /* old ESP (want 0x4FFC) */
    movl    %eax, 0x00002014
    movl    16(%esp), %eax             /* old SS (want 0x23) */
    movl    %eax, 0x00002018
    movl    %esp, %eax
    movl    %eax, 0x0000201C           /* new ESP (want 0x8FEC) */
    lret    $4                         /* discard the 1 copied param */

    .align 16
    .global h31
h31:
    /* Exhaustive order check: param[i] must equal 0xA5000000|i at 8+4i. */
    xorl    %ebx, %ebx                 /* mismatch count */
    xorl    %ecx, %ecx
1:  movl    8(%esp,%ecx,4), %eax
    movl    %ecx, %edx
    orl     $0xA5000000, %edx
    cmpl    %edx, %eax
    je      2f
    incl    %ebx
2:  incl    %ecx
    cmpl    $31, %ecx
    jb      1b
    movl    %ebx, 0x00002020           /* want 0 */
    movl    132(%esp), %eax            /* 8+4*31: old ESP (want 0x4F84) */
    movl    %eax, 0x00002024
    movl    136(%esp), %eax            /* old SS (want 0x23) */
    movl    %eax, 0x00002028
    movl    %esp, %eax
    movl    %eax, 0x0000202C           /* new ESP (want 0x8F74) */
    movl    0(%esp), %eax
    movl    %eax, 0x00002030           /* return EIP (want after31) */
    lret    $124                       /* discard the 31 copied params */

    /* ===================== CPL3 callee (SAME privilege) ===================
     * Gate 0x48 -> code3: NO stack switch, NO parameter copy. The return
     * frame is 2 dwords (gate width): 0(%esp)=retEIP 4(%esp)=retCS, and the
     * caller's two dwords sit at 8/12(%esp).                              */
    .align 16
    .global h3same
h3same:
    movl    8(%esp), %eax              /* caller dword 2 (want 0xC6000001) */
    movl    %eax, 0x0000203C
    movl    12(%esp), %eax             /* caller dword 1 (want 0xC6000000) */
    movl    %eax, 0x00002040
    movl    4(%esp), %eax              /* return CS (want 0x1B) */
    movl    %eax, 0x00002044
    movw    %ss, %ax
    movzwl  %ax, %eax
    movl    %eax, 0x00002048           /* SS UNCHANGED (want 0x23) */
    lret    $8                         /* same-priv RETF discards the 2 dwords */

    /* ===================== diagnostic fault catchers =======================
     * Reached ONLY on an unexpected fault. The exit then carries the
     * 0xBAD0FF0x sentinels + a nonzero 0x20F0, and the stream diverges.     */
    .align 16
    .global gp_catch
gp_catch:
    movl    (%esp), %eax               /* #GP error code */
    movl    %eax, 0x000020F0
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b

    .align 16
    .global pf_catch
pf_catch:
    movl    (%esp), %eax               /* #PF error code */
    movl    %eax, 0x000020F4
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  jmp     9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
