/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * REVIEW2_aug2 C-07 + M-02 — the TSS I/O permission bitmap.
 *
 * Four independent bugs lived in one FSM arm, and NOTHING in the corpus exercised it:
 * S_IOPERM consults across the whole system suite measured ZERO, so verify-all being
 * green said nothing at all about them.
 *
 *   C-07(a) the map base was read from mem_rdata[15:0]. The bus arm addresses
 *           tr_base+0x64 and the base is at TSS offset 0x66, so it is the HIGH half.
 *           [15:0] is the trap/reserved field at 0x64-0x65 -- normally ZERO, so the
 *           apparent base was 0 and reads went into unrelated TSS fields.
 *   C-07(b) the bit index was port[2:0] + (port[1:0]<<3), giving 0,9,18,27,4,13,22,31
 *           for ports 0..7 -- mostly a bit from a DIFFERENT byte of the dword.
 *   C-07(c) only the FIRST port was checked; word/dword IN/OUT cover 2-4 ports, so a
 *           permitted first port let the rest through. A privilege bypass.
 *   M-02    base >= limit was rejected; TSS limits are INCLUSIVE, so base == limit
 *           still names a byte covering ports 0-7.
 *
 * SETUP: TSS at 0x3000 with a NONZERO map base (0x68), bitmap byte for ports
 * 0x100-0x107 at 0x3068+0x20 = 0x3088 set to 0xAA -- odd ports DENIED, even PERMITTED.
 * CPL3 with IOPL=0, so every I/O access consults the bitmap.
 *
 * THE WITNESS is the #GP count in ecx. It discriminates all three C-07 bugs:
 *     correct                     -> 6
 *     C-07(c) present (1st port)  -> 4  (the two word accesses stop faulting)
 *     C-07(b) present (bad index) -> a different set of byte ports faults
 *     C-07(a) present (base 0)    -> reads land in unrelated TSS bytes
 *
 * Exit: isa-debug-exit 0x42 -> 133. ecx is read from the final trace record.
 *
 * ============================ STATUS: DOES NOT PASS YET =====================
 * NOT wired into any gate. Committed so the setup is not lost, and so the next
 * session starts from a measured position rather than a blank page.
 *
 * WHERE IT STOPS: Ventium reaches CPL3 (cs=0x1b confirmed in the trace) and then goes
 * QUIESCENT at the first CPL3 OUT, around pc=0x000f0175. The harness QEMU also fails to
 * reach the exit (timeout).
 *
 * THAT IS AMBIGUOUS AND MUST NOT BE READ AS AN RTL FINDING. Two live possibilities:
 *   (a) a real stall in the S_IOPERM path (the TSS permission read never completing);
 *   (b) a defect in this test's TSS/descriptor setup -- QEMU not reaching the exit
 *       either points this way, since QEMU's I/O permission path is known good.
 * (b) is the more likely reading and should be eliminated first.
 *
 * BUGS ALREADY FOUND AND FIXED IN THIS FILE, each caught by comparing against QEMU
 * rather than by reading it:
 *   1. the exit OUT also faults at CPL3/IOPL=0; with a stale resume address the
 *      handler looped forever. The handler now performs the exit itself at CPL0.
 *   2. IRET loads CS and SS but NOT DS/ES, so at CPL3 they still held the DPL0
 *      selector and the first data store faulted with no resume address stashed.
 *   3. an early reading of "ecx=23" as a fault count was wrong -- ecx is the zeroing
 *      loops' counter, and the run had merely been cut off by --max-insn.
 * ===========================================================================
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
     * 0x20(sel 0x23) data3, 0x28 TSS(base 0x3000, limit 0x2FF) */
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
    movl    $0x300002FF, 0x0528          /* TSS base[15:0]=0x3000 limit=0x2FF */
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
     * Built HERE, in .code32, not in the 16-bit stub: $gp_handler lives in .text32 and
     * a 16-bit relocation against it truncates (R_386_16), which is the same trap the
     * psegdl test hit with its far jump. */
    movl    $0x00001000, %edi
    movl    $0x00000200, %ecx
3:  movl    $0, (%edi)
    addl    $4, %edi
    loop    3b

    movl    $0x00001068, %ebx            /* 0x1000 + 0x0D*8 */
    movl    $gp_handler, %eax
    movw    %ax, 0(%ebx)
    movw    $0x0008, 2(%ebx)
    movw    $0x8E00, 4(%ebx)             /* present, DPL0, 32-bit interrupt gate */
    shrl    $16, %eax
    movw    %ax, 6(%ebx)

    movw    $0x07FF, 0x0490
    movl    $0x00001000, 0x0492
    lidt    0x0490

    /* zero the TSS + bitmap region */
    movl    $0x00003000, %edi
    movl    $0x000000C0, %ecx
2:  movl    $0, (%edi)
    addl    $4, %edi
    loop    2b

    movl    $0x00080000, 0x00003008      /* ESP0 */
    movl    $0x00000010, 0x0000300C      /* SS0  */
    movw    $0x0068,     0x00003066      /* I/O map base = 0x68  (NONZERO: C-07a) */

    /* bitmap byte covering ports 0x100-0x107 = 0x3068 + (0x100>>3) = 0x3088.
     * 0xAA = bits 1,3,5,7 -> ports 0x101,0x103,0x105,0x107 DENIED. */
    movb    $0xAA, 0x00003088

    movw    $0x0028, %ax
    ltr     %ax

    movl    $0, 0x00002000               /* #GP counter */
    movl    $0, 0x00002020               /* done flag */

    /* drop to CPL3 with IOPL=0 so the bitmap is actually consulted */
    pushl   $0x23
    pushl   $0x00088000
    pushl   $0x00000002                  /* EFLAGS: IF=0, IOPL=0 */
    pushl   $0x1B
    pushl   $cpl3_entry
    iret

    .global cpl3_entry
cpl3_entry:
    /* IRET loads CS and SS but NOT DS/ES -- they still hold 0x10 (DPL0) here, so at
     * CPL3 the very first data store would #GP, and with no resume address stashed yet
     * the handler looped. Both QEMU (timeout) and Ventium (max-insn, ecx=23 faults for
     * 10 accesses) reported that before it could be mistaken for an RTL bug. */
    movw    $0x23, %ax
    movw    %ax, %ds
    movw    %ax, %es

    /* --- eight BYTE accesses, ports 0x100..0x107: all eight bit positions ------ */
    movl    $t1, 0x00002010
    movw    $0x0100, %dx
    outb    %al, %dx
t1: movl    $t2, 0x00002010
    movw    $0x0101, %dx
    outb    %al, %dx                     /* denied */
t2: movl    $t3, 0x00002010
    movw    $0x0102, %dx
    outb    %al, %dx
t3: movl    $t4, 0x00002010
    movw    $0x0103, %dx
    outb    %al, %dx                     /* denied */
t4: movl    $t5, 0x00002010
    movw    $0x0104, %dx
    outb    %al, %dx
t5: movl    $t6, 0x00002010
    movw    $0x0105, %dx
    outb    %al, %dx                     /* denied */
t6: movl    $t7, 0x00002010
    movw    $0x0106, %dx
    outb    %al, %dx
t7: movl    $t8, 0x00002010
    movw    $0x0107, %dx
    outb    %al, %dx                     /* denied */

    /* --- WORD accesses: the first port is PERMITTED, the second DENIED --------- *
     * These are what C-07(c) missed entirely: checking only the first port let
     * both through.                                                              */
t8: movl    $t9, 0x00002010
    movw    $0x0100, %dx
    outw    %ax, %dx                     /* covers 0x100 (ok) + 0x101 (denied) */
t9: movl    $t10, 0x00002010
    movw    $0x0102, %dx
    outw    %ax, %dx                     /* covers 0x102 (ok) + 0x103 (denied) */
t10:
    /* The exit OUT also faults (IOPL=0 at CPL3), so it cannot be issued from here --
     * and with a stale resume address it LOOPED forever. Both QEMU (timeout) and
     * Ventium (max-insn) reported that, which is how the bug was caught before it was
     * mistaken for an RTL fault. Set a done flag and let the handler exit at CPL0.
     */
    movl    $1,   0x00002020             /* done flag */
    movl    $t11, 0x00002010
    movw    $0x00F4, %dx
    outb    %al, %dx                     /* faults -> handler sees the flag and exits */
t11:
    hlt
    jmp     t11

    /* #GP handler (CPL0 via TSS ESP0). Cross-priv frame with an error code:
     *   [esp]=err  [esp+4]=EIP  [esp+8]=CS  [esp+12]=EFLAGS  [esp+16]=ESP  [esp+20]=SS
     * Count the fault, replace the resume EIP with the stashed one, drop the error
     * code, and IRET back to CPL3. */
    .global gp_handler
gp_handler:
    cmpl    $1, 0x00002020
    je      gp_done
    incl    0x00002000
    movl    0x00002010, %eax
    movl    %eax, 4(%esp)
    addl    $4, %esp
    iret
gp_done:
    /* CPL0: IOPL does not gate I/O here, so the exit actually goes out. ecx carries
     * the #GP count into the final trace record. */
    movl    0x00002000, %ecx
    movb    $0x42, %al
    movw    $0x00F4, %dx
    outb    %al, %dx
4:  hlt
    jmp     4b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
