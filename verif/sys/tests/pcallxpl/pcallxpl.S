/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 C-06 (call-gate half): a far CALL through a call gate to a MORE
 * privileged code segment must SWITCH STACKS -- load SS:ESP from the TSS ssN/espN for
 * the target CPL, copy `param count` dwords from the caller's stack, then push the
 * caller's SS:ESP and the return CS:EIP on the NEW stack.
 *
 * This core does not implement it. Unlike the RETF outer-return half (fixed in
 * 0562454), it does NOT fail silently: the cross-privilege arm HALTS LOUDLY with its
 * own tag (0xDB), precisely so it could not be mistaken for a working transfer. That
 * is why this half was left for last -- it was already fail-safe.
 *
 * This image gets to ring 3 using the OUTER RETF that 0562454 fixed, then calls back
 * inward through a DPL-3 gate whose target is a DPL-0 code segment.
 *
 *   unimplemented  the core halts at the gate; NOTHING retires past the lcall, so the
 *                  witness never reaches its ring-0 value
 *   implemented    k0_entry runs at CPL 0 on the TSS stack -> ebp = 0x0CA60000 | ss,
 *                  which must be 0x10 (ESP0's segment), and esi = the caller's ESP
 *                  as recovered FROM THE FRAME, proving the old stack was pushed
 *
 * The witness deliberately names the RING-0 SS and the recovered caller ESP rather
 * than "did we reach CPL 0", for the same reason pretfout names the stack: a broken
 * implementation that jumped to k0_entry on the CALLER's stack would satisfy any
 * privilege-level-only check while being exactly the escalation the finding is about.
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

    /* GDT at 0x0500:
     *   0x08 code0   0x10 data0   0x18 code3   0x20 data3   0x28 call gate   0x30 TSS */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000ffff, 0x0508        /* 0x08 code32 DPL0 */
    movl    $0x00cf9a00, 0x050c
    movl    $0x0000ffff, 0x0510        /* 0x10 data32 DPL0 */
    movl    $0x00cf9200, 0x0514
    movl    $0x0000ffff, 0x0518        /* 0x18 code32 DPL3 -> 0x1B */
    movl    $0x00cffa00, 0x051c
    movl    $0x0000ffff, 0x0520        /* 0x20 data32 DPL3 -> 0x23 */
    movl    $0x00cff200, 0x0524
    /* 0x28 call gate and 0x30 TSS are built in pm_entry: both need 32-bit values
     * derived from .text32 labels, which .code16 cannot name (R_386_16). */

    movw    $0x0037, 0x0480            /* GDT limit = 7*8-1 */
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

    /* ---- GDT[5] = 0x28: 32-bit CALL GATE (type 0xC), DPL 3, param count 0 ------
     * low  = {target selector 0x08} << 16 | offset[15:0]
     * high = offset[31:16] | P=1 DPL=3 type=0xC (0xEC) << 8 | param count (0) */
    movl    $k0_entry, %eax
    andl    $0x0000ffff, %eax
    orl     $0x00080000, %eax
    movl    %eax, 0x0528
    movl    $k0_entry, %eax
    andl    $0xffff0000, %eax
    orl     $0x0000ec00, %eax          /* P|DPL3|type 0xC, param count 0 */
    movl    %eax, 0x052c

    /* ---- GDT[6] = 0x30: 32-bit TSS, base 0x4000, limit 0x67, access 0x89 ------ */
    movl    $0x40000067, 0x0530
    movl    $0x00008900, 0x0534

    /* ---- TSS at 0x4000: zero it, then SS0 @ 0x08 and ESP0 @ 0x04 -------------- */
    movl    $0x00004000, %edi
    movl    $32, %ecx                  /* 0x68 bytes rounded up */
    xorl    %eax, %eax
    rep stosl
    movl    $0x00006000, 0x00004004    /* ESP0 -- distinct from every other stack */
    movl    $0x00000010, 0x00004008    /* SS0  */
    movw    $0x0068,     0x00004066    /* I/O map base = TSS limit+1 (no bitmap) */

    movw    $0x0030, %ax
    ltr     %ax

    /* IOPL 3 so the ring-0 tail can drive 0xF4 after we come back in. (CPL will be 0
     * there anyway; this is for the ring-3 leg if it ever needs it.) */
    pushfl
    orl     $0x00003000, (%esp)
    popfl

    xorl    %ebp, %ebp                 /* witness: 0 = the gate never transferred */
    xorl    %esi, %esi

    /* ---- out to ring 3 via the OUTER RETF (fixed in 0562454) ------------------ */
    pushl   $0x00000023                /* SS  */
    pushl   $0x00005000                /* ESP -- the ring-3 stack */
    pushl   $0x0000001B                /* CS  */
    pushl   $r3_entry                  /* EIP */
    lret

    .global r3_entry
r3_entry:
    /* CPL 3, on the ring-3 stack. THE FINDING: call INWARD through the gate.
     * Hand-encoded far call ptr16:32 -- the gate selector is 0x2B (0x28 | RPL 3). */
    .byte   0x9A
    .long   0                          /* offset ignored for a gate */
    .word   0x002B

    /* Reached only if the gate returned (it does not; k0_entry exits). */
    movl    $0xBADBAD00, %ebp
    jmp     r3_spin

    .global k0_entry
k0_entry:
    /* CPL 0 now, and this must be the TSS stack, not the caller's.
     * The gate frame with param count 0 is:
     *   0(%esp) = return EIP   4(%esp) = return CS
     *   8(%esp) = caller ESP  12(%esp) = caller SS */
    movl    %ss, %eax
    andl    $0x0000ffff, %eax
    orl     $0x0CA60000, %eax          /* witness = 0x0CA6_00<ss>, want ss = 0x10 */
    movl    %eax, %ebp
    movl    8(%esp), %esi              /* the caller's ESP, recovered from the frame */
    jmp     k0_exit

r3_spin:
    jmp     r3_spin

k0_exit:
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
9:  hlt
    jmp     9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
