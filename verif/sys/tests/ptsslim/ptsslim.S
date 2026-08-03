/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 C-03 (fifth bullet): a cross-privilege delivery must BOUND the
 * TSS.ssN:espN read against tr_limit and raise #TS instead of reading past the TSS.
 *
 * tr_valid and tr_limit existed in the core and were consumed by NOTHING -- they sat
 * in the lint sink at core.sv with a comment saying the negative cases "would consult"
 * them. A TSS truncated before SS0:ESP0 therefore had its stack selector and pointer
 * read out of whatever memory followed the TSS, and the handler ran on it.
 *
 * HOW THIS DISCRIMINATES -- both builds COMPLETE, with different witnesses, so there
 * is no hang/quiesce ambiguity to interpret:
 *
 *   The TSS *memory* at 0x3000 is fully and correctly populated (ESP0=0x88000,
 *   SS0=0x10). Only the *descriptor limit* is truncated, to 0x0007 -- which stops
 *   short of SS0 at offset 8..11. So:
 *
 *     with the fix     tss_last(11) > tr_limit(7) -> #TS(0x28) BEFORE the read.
 *                      The #TS gate targets a CONFORMING DPL3 segment, so it is
 *                      delivered at CPL3 with no stack switch (it must not need the
 *                      TSS, or the fault could not be reported at all).
 *                      -> ts_handler, ebp = 0x75510028 (0x28 = the TR selector)
 *     without the fix  the read runs past the limit, finds the perfectly good SS0
 *                      and ESP0 that are sitting there, and delivery SUCCEEDS.
 *                      -> sys_bug at CPL0,  ebp = 0x0BAD0040
 *
 * S_LTR validates the TSS selector, type and Present bit but NOT its limit, so the
 * short descriptor loads without complaint and the delivery-time bound is reachable.
 * (IA-32 also requires #TS on LTR when the TSS limit is below 0x67. That is a real
 * additional gap, but it is not what C-03 asks for, and adding it here would make
 * THIS test unreachable -- noted rather than silently fixed.)
 *
 * SEEN TO FAIL: measured against a build with the tr_valid/tr_limit guard removed.
 *
 * Exit: isa-debug-exit with 0x42 -> status 133, ebp = 0x75510028.
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

    /* --- GDT (7 entries = 56 bytes) at linear 0x0500 ---
     * idx0 null
     * idx1 0x08 code32 flat DPL0        access 0x9A gran 0xCF
     * idx2 0x10 data32 flat DPL0        access 0x92 gran 0xCF
     * idx3 0x18 code32 flat DPL3        access 0xFA gran 0xCF
     * idx4 0x20 data32 flat DPL3        access 0xF2 gran 0xCF
     * idx5 0x28 TSS32 available, base 0x3000, LIMIT 0x0007  <- TRUNCATED
     * idx6 0x30 code32 flat DPL3 CONFORMING  access 0xFE gran 0xCF
     *
     * idx6 is what makes the fault reportable: a #TS taken at CPL3 whose handler CS
     * is non-conforming DPL0 would itself be a cross-privilege delivery, would need
     * the same broken TSS, and would escalate instead of being observed. A conforming
     * DPL3 target keeps CPL=3 and pushes on the current stack.
     */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* idx1 0x08 code0 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* idx2 0x10 data0 */
    movl    $0x00CF9200, 20(%ebx)
    movl    $0x0000FFFF, 24(%ebx)       /* idx3 0x18 code3 */
    movl    $0x00CFFA00, 28(%ebx)
    movl    $0x0000FFFF, 32(%ebx)       /* idx4 0x20 data3 */
    movl    $0x00CFF200, 36(%ebx)
    /* idx5 0x28 TSS32: limit[15:0]=0x0007, base[15:0]=0x3000 -> 0x30000007 */
    movl    $0x30000007, 40(%ebx)
    movl    $0x00008900, 44(%ebx)       /* access 0x89 (avail 32-bit TSS), gran 0 */
    movl    $0x0000FFFF, 48(%ebx)       /* idx6 0x30 code3 CONFORMING */
    movl    $0x00CFFE00, 52(%ebx)       /* access 0xFE = P|DPL3|S|code|conforming|R */

    movw    $0x0037, 0x0480             /* GDT limit = 56-1 */
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
    movl    $0x00090000, %esp

    /* ---- TSS memory @ 0x3000: fully and CORRECTLY populated ------------------
     * This is the point of the test. The bytes are all there and valid; only the
     * DESCRIPTOR says the segment ends at offset 7. A core that ignores the limit
     * finds a working SS0:ESP0 and proceeds, which is exactly the silent behaviour
     * the finding describes -- and is why the witness has to distinguish WHICH
     * handler ran rather than merely whether something faulted. */
    movl    $0x00003000, %edi
    xorl    %eax, %eax
    movl    $26, %ecx                   /* 104 bytes */
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0x00088000, 0x00003004     /* ESP0 -- past the truncated limit */
    movl    $0x00000010, 0x00003008     /* SS0  -- past the truncated limit */
    movw    $0x0068, 0x00003066

    movw    $0x0028, %ax
    ltr     %ax                         /* LTR does NOT check the limit -> loads */

    /* ---- IDT @ 0x1000 -------------------------------------------------------
     * vector 0x40 -> sys_bug   via selector 0x08 (DPL0, NON-conforming) = the
     *                cross-privilege delivery under test. Reaching its handler
     *                means the truncated TSS was read successfully.
     * vector 10 (#TS) -> ts_handler via selector 0x30 (DPL3, CONFORMING) = same
     *                privilege, no stack switch, so it does not depend on the TSS.
     * Gate attr 0xEE = P, DPL3, 32-bit interrupt gate. */
    movl    $0x00001000, %edi
    xorl    %eax, %eax
    movl    $512, %ecx                  /* zero the whole 256-gate IDT */
2:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    2b

    movl    $sys_bug, %ebx              /* vector 0x40 -> 0x1000 + 0x40*8 */
    movl    $0x00001200, %edi
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax           /* selector 0x08 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x0000EE00, %eax
    movl    %eax, 4(%edi)

    movl    $ts_handler, %ebx           /* vector 10 (#TS) -> 0x1000 + 10*8 */
    movl    $0x00001050, %edi
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00300000, %eax           /* selector 0x30 (conforming DPL3) */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x0000EE00, %eax
    movl    %eax, 4(%edi)

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    xorl    %eax, %eax
    xorl    %ebx, %ebx
    xorl    %ecx, %ecx
    xorl    %edx, %edx
    xorl    %esi, %esi
    xorl    %ebp, %ebp

    /* ---- down to CPL3, with IOPL=3 ------------------------------------------
     * IOPL=3 matters: the #TS handler runs at CPL3 and performs the isa-debug-exit
     * OUT itself. It cannot ask CPL0 to do it -- that would be another cross-priv
     * delivery through the same broken TSS, which would fault again instead of
     * exiting. With IOPL >= CPL the I/O permission bitmap is not consulted, which
     * is just as well: the bitmap lives past this TSS's limit too. */
    pushl   $0x00000023                 /* SS = data3 (RPL3) */
    pushl   $0x00080000                 /* ESP = CPL3 stack top */
    pushfl
    orl     $0x00003200, (%esp)         /* IF=1 (0x200) + IOPL=3 (0x3000) */
    pushl   $0x0000001B                 /* CS = code3 (RPL3) */
    pushl   $user_entry
    iret

    /* ============================ CPL3 USER TASK ========================= */
    .global user_entry
user_entry:
    movw    $0x23, %ax
    movw    %ax, %ds
    movw    %ax, %es

    int     $0x40                       /* cross-priv: must #TS on the short TSS */

    /* If INT 0x40 returned at all, neither expected path was taken. Leave ebp at 0
     * so the gate reports failure rather than reading a stale witness. */
    xorl    %ebp, %ebp
    jmp     cpl3_exit

    /* ---- #TS handler: runs at CPL3 (conforming target, no stack switch) ------
     * Same-privilege frame WITH an error code:
     *   0(%esp)=error code  4(%esp)=eip  8(%esp)=cs  12(%esp)=eflags
     * The error code is the TR selector with the low two bits cleared = 0x28. */
    .global ts_handler
ts_handler:
    movl    0(%esp), %eax
    andl    $0x0000FFFF, %eax
    orl     $0x75510000, %eax           /* witness = 0x7551_00<errcode> */
    movl    %eax, %ebp
    movl    4(%esp), %esi               /* saved EIP, for corroboration */
    /* REVIEW2_aug2 C-03 (first bullet): the SAVED CS on this frame is the direct
     * witness for the CS-staging half. The #TS is raised in S_INT_CS, i.e. LATE in
     * the INT 0x40 delivery. S_INT_CS used to install the handler's CS the moment the
     * descriptor was accepted, so this frame reported CS=0x08 -- a selector the
     * interrupted code never executed in. With the hidden state staged to the single
     * commit point at the end of S_INT_PUSH it reports the real interrupted CS:
     *   staged      edi = 0x0000001B   (the CPL3 user segment that ran INT 0x40)
     *   not staged  edi = 0x00000008   (the handler CS, installed prematurely) */
    movl    8(%esp), %edi               /* saved CS */
cpl3_exit:
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx                    /* allowed: IOPL=3 >= CPL=3 */
9:  jmp     9b

    /* ---- the "delivery proceeded" handler: CPL0, on the TSS stack ------------
     * Reaching this at all means the core read SS0:ESP0 from beyond the TSS limit
     * and switched to them. That IS the finding, so it is a FAILING witness. */
    .global sys_bug
sys_bug:
    movl    $0x0BAD0040, %ebp
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
8:  hlt
    jmp     8b

    .section .reset, "ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
