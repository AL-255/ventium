/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW_Aug3 M-01 — an I/O access whose extent wraps past port 0xFFFF must
 * be denied #GP(0) outright, never decided by ADJACENT bitmap memory.
 *
 * The defect (core.sv, pre-fix): `ioperm_last` was only 16 bits. A word or
 * dword IN/OUT beginning near 0xFFFF wrapped the last-port computation before
 * the bitmap limit check, and the permission mask then indexed bits beyond
 * the final bitmap byte in the fetched dword -- the decision depended on
 * adjacent bitmap memory rather than an explicit end-of-I/O-space rule. The
 * fix computes the last port in 17 bits (ioperm_last17) and denies outright
 * when bit 16 sets (ioperm_wrap), before any bitmap consult.
 *
 * ORACLE -- QEMU 8.2.2 AGREES ARCHITECTURALLY, BY A DIFFERENT ROUTE (measured
 * in the pinned harness source, tcg/sysemu/seg_helper.c:193 helper_check_io):
 * QEMU has no wrap guard either, but it evaluates a 16-bit window: for a
 * denied-width access at the top of the I/O space the window's high bits land
 * in the byte AFTER the port-0xFFFF byte -- the I/O bitmap TERMINATOR, which
 * IA-32 requires to be 0xFF (SDM Vol.3A 13.5.3: "the last byte of the bitmap
 * must be 0xFF"). With the terminator in place QEMU raises #GP(0) for exactly
 * the accesses the RTL's explicit wrap rule denies, and permits exactly the
 * in-space ones -- so this test is graded DIFFERENTIALLY. The test's bitmap
 * holds the architecturally-required 0xFF terminator, which is what makes the
 * two readings coincide.
 *
 * CORRECTION TO THE TASK BRIEF (measured against both the fix and QEMU): a
 * DWORD at 0xFFFC covers ports 0xFFFC..0xFFFF -- its last port IS 0xFFFF, so
 * nothing wraps and BOTH oracles PERMIT it. The wrapping dword begins at
 * 0xFFFD. The brief's "IN dword at 0xFFFC must #GP" is therefore used here as
 * the exact-boundary PERMITTED control (case 5), and the denied dword case
 * uses DX=0xFFFD (case 2).
 *
 * THE CASES (CPL3, IOPL=0, TSS bitmap ALLOWS all of 0xFFF8-0xFFFF, byte for
 * port 0xFFF0 SET, terminator byte 0xFF present):
 *   case 1  out %ax,%dx   DX=0xFFFF  word covers 0xFFFF+0x10000 -> #GP(0)
 *   case 2  in  %dx,%eax  DX=0xFFFD  dword covers ..0x10000      -> #GP(0)
 *           (denied, so no IN data is ever consumed -- no oracle data skew)
 *   case 3  outb %al,%dx  DX=0xFFF0  bitmap bit SET              -> #GP(0)
 *           (proves the top-of-space bitmap bits are genuinely consulted)
 *   case 4  outb %al,%dx  DX=0xFFFF  single byte, no wrap        -> PERMITTED
 *   case 5  out %eax,%dx  DX=0xFFFC  last port == 0xFFFF exactly -> PERMITTED
 *
 * THE WITNESSES (marker page, pulled into the GPRs before the exit; the exit
 * clobbers EAX/DX, so ecx/esi/ebx carry them):
 *   ecx = 3  #GP deliveries (cases 1,2,3), each with error code 0
 *   esi = 3  handler confirmations that the error code on the frame was 0
 *   ebx = 2  permitted cases that ran to completion (cases 4,5)
 *
 * SETUP mirrors pioperm: TSS at 0x3000, map base 0x68, but the TSS limit is
 * 0x2068 so the bitmap spans offsets 0x68..0x2068 -- the full 8 KiB map plus
 * the terminator byte, because a port near 0xFFFF must be COVERED (an
 * uncovered port is denied for a different reason and would prove nothing).
 * Bitmap bytes: 0x2066 = 0x01 (port 0xFFF0 denied), 0x2067 = 0x00 (ports
 * 0xFFF8-0xFFFF permitted), 0x2068 = 0xFF (terminator), 0x86 = 0x00 (port
 * 0xF4 permitted -- the exit leaves from CPL3, like pioperm).
 *
 * NEGATIVE CONTROL (REQUIRED, see manifest.json): the HEAD TB's 16-bit
 * ioperm_last wraps, so cases 1/2 pass the limit check vacuously and the bit
 * test reads adjacent memory: with the terminator byte 0xFF the adjacent bits
 * happen to deny case 1 (word @0xFFFF) but case 2's mask (ports 0xFFFD..) sits
 * inside the CLEAR byte 0x2067 -- so HEAD PERMITS the wrapping dword IN (and
 * consumes io_rdata into EAX): DIVERGENT on the #GP count AND on EAX.
 *
 * GNU-as; no nasm. Flat 64 KiB -bios image; reset F000:FFF0.
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

    /* GDT at 0x0500: null, 0x08 code0, 0x10 data0, 0x18(sel 0x1B) code3,
     * 0x20(sel 0x23) data3, 0x28 TSS(base 0x3000, limit 0x2068) */
    movl    $0x00000000, 0x0500
    movl    $0x00000000, 0x0504
    movl    $0x0000FFFF, 0x0508
    movl    $0x00CF9A00, 0x050C
    movl    $0x0000FFFF, 0x0510
    movl    $0x00CF9200, 0x0514
    movl    $0x0000FFFF, 0x0518
    movl    $0x00CFFA00, 0x051C          /* code DPL3 */
    movl    $0x0000FFFF, 0x0520
    movl    $0x00CFF200, 0x0524          /* data DPL3 */
    movl    $0x30002068, 0x0528          /* TSS base[15:0]=0x3000 limit=0x2068 */
    movl    $0x00008900, 0x052C          /* base[31:16]=0, access 0x89 (32-bit TSS) */

    movw    $0x002F, 0x0480              /* GDT limit = 6*8-1 */
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $1, %eax
    movl    %eax, %cr0
    .byte   0x66, 0xEA
    .long   pm32_entry
    .word   0x08

    .code32
    .section .text32,"ax"
    .global pm32_entry
pm32_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x00070000, %esp

    /* IDT at 0x1000; gate 0x0D (#GP) -> sel 0x08, DPL0 interrupt gate.
     * Zero only vectors 0..15 (32 dwords); low RAM resets to 0. */
    movl    $0x00001000, %edi
    movl    $32, %ecx
    xorl    %eax, %eax
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b

    movl    $gp_handler, %ebx
    movl    $0x00001068, %edi            /* 0x1000 + 0x0D*8 */
    call    set_gate0

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* zero the TSS header (26 dwords) + the two bitmap dwords the cases read
     * (0x5064 covers bytes 0x2064-0x2067 incl. the port-0xFFF8..0xFFFF byte;
     *  0x5084 covers byte 0x86 = port 0xF4's byte). The rest of the bitmap is
     * never read (wrap cases fault before the consult). */
    movl    $0x00003000, %edi
    movl    $26, %ecx
    xorl    %eax, %eax
1:  movl    %eax, (%edi)
    addl    $4, %edi
    loop    1b
    movl    $0, 0x00005064
    movl    $0, 0x00005068
    movl    $0, 0x00005084

    /* 32-bit TSS: ESP0 @ +0x04, SS0 @ +0x08, I/O map base @ +0x66. */
    movl    $0x00080000, 0x00003004      /* ESP0 */
    movl    $0x00000010, 0x00003008      /* SS0  */
    movw    $0x0068,     0x00003066      /* I/O map base = 0x68 */

    /* bitmap: byte 0x2066 (ports 0xFFF0-0xFFF7) = 0x01 -> port 0xFFF0 DENIED;
     * byte 0x2067 (ports 0xFFF8-0xFFFF) = 0x00 -> PERMITTED;
     * byte 0x2068 = 0xFF -- the architecturally-required bitmap TERMINATOR
     * (SDM Vol.3A 13.5.3). QEMU's helper_check_io evaluates a 16-bit window
     * for the top-of-space accesses, so its wrap denial comes via this byte;
     * the RTL denies explicitly (ioperm_wrap). */
    movb    $0x01, 0x00005066
    movb    $0xFF, 0x00005068

    movw    $0x0028, %ax
    ltr     %ax

    movl    $0, 0x00002000               /* #GP counter */
    movl    $0, 0x00002004               /* err-code-was-zero counter */
    movl    $0, 0x00002008               /* permitted-case counter */

    /* drop to CPL3 with IOPL=0 so every I/O access consults the bitmap */
    pushl   $0x23
    pushl   $0x00088000
    pushl   $0x00000002                  /* EFLAGS: IF=0, IOPL=0 */
    pushl   $0x1B
    pushl   $cpl3_entry
    iret

    .global cpl3_entry
cpl3_entry:
    /* IRET nulled DS/ES (DPL0 < new CPL3); reload before any store. */
    movw    $0x23, %ax
    movw    %ax, %ds
    movw    %ax, %es

    /* --- case 1: WORD out at 0xFFFF -- extent wraps the I/O space -------- */
    movl    $t1, 0x00002010
    movw    $0xFFFF, %dx
    out     %ax, %dx                     /* denied: covers 0xFFFF + 0x10000 */

    /* --- case 2: DWORD in at 0xFFFD -- extent wraps ------------------------ *
     * Denied, so no IN data is consumed in EITHER oracle (no data skew).    */
t1: movl    $t2, 0x00002010
    movw    $0xFFFD, %dx
    in      %dx, %eax                    /* denied: covers 0xFFFD..0x10000 */

    /* --- case 3: BYTE out at 0xFFF0 -- the bitmap bit is SET --------------- *
     * Control: the top-of-space bitmap bits are genuinely consulted.        */
t2: movl    $t3, 0x00002010
    movw    $0xFFF0, %dx
    outb    %al, %dx                     /* denied: bit 0 of byte 0x2066 set */

    /* --- case 4: BYTE out at 0xFFFF -- PERMITTED (single byte, no wrap) --- */
t3: movw    $0xFFFF, %dx
    outb    %al, %dx                     /* permitted: bit 7 of byte 0x2067 clear */
    incl    0x00002008

    /* --- case 5: DWORD out at 0xFFFC -- PERMITTED (last port == 0xFFFF) ---- *
     * The exact boundary: 0xFFFC+3 = 0xFFFF, nothing past the I/O space.    */
    movw    $0xFFFC, %dx
    out     %eax, %dx                    /* permitted */
    incl    0x00002008

    /* witnesses -> the trace (ecx/esi/ebx survive the exit; eax/dx do not) */
    movl    0x00002000, %ecx             /* #GP count            (want 3) */
    movl    0x00002004, %esi             /* err==0 confirmations (want 3) */
    movl    0x00002008, %ebx             /* permitted cases ran  (want 2) */
    movb    $0x42, %al                   /* isa-debug-exit status (0x42<<1)|1 = 133;
                                          * AL was clobbered by the handler's stash */
    movw    $0x00F4, %dx
    outb    %al, %dx                     /* PERMITTED by the bitmap: exits from CPL3 */
t11:
    hlt
    jmp     t11

    /* #GP handler (CPL0 via TSS ESP0). Cross-priv frame with an error code:
     *   [esp]=err  [esp+4]=EIP  [esp+8]=CS  [esp+12]=EFLAGS  [esp+16]=ESP  [esp+20]=SS
     * Count the fault, confirm the error code is 0 (M-01 denials are #GP(0),
     * never a selector), replace the resume EIP with the stashed one, drop
     * the error code, and IRET back to CPL3. DS is still 0x23 (usable at CPL0). */
    .global gp_handler
gp_handler:
    incl    0x00002000
    cmpl    $0, 0(%esp)
    jne     1f
    incl    0x00002004
1:  movl    0x00002010, %eax
    movl    %eax, 4(%esp)
    addl    $4, %esp
    iret

    /* ---- IDT gate builder (EBX = handler offset, EDI = gate slot) ---- */
set_gate0:
    movl    %ebx, %eax
    andl    $0x0000FFFF, %eax
    orl     $0x00080000, %eax            /* selector 0x08 */
    movl    %eax, 0(%edi)
    movl    %ebx, %eax
    andl    $0xFFFF0000, %eax
    orl     $0x00008E00, %eax            /* P, DPL0, 32-bit interrupt gate */
    movl    %eax, 4(%edi)
    ret

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
