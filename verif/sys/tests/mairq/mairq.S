/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M-A — live-board interrupt-injection smoke (PS R_INTR seam on silicon).
 *
 * The cheapest make-or-break hardware gate for FreeDOS-on-board: it proves the
 * deployed bitstream honours cosim_en (IO bridge) AND soc_en (external-INTR
 * divert) simultaneously, and that the PS R_INTR injection + INTA-seen handshake
 * actually delivers a real-mode interrupt through the IVT on real hardware. No
 * peripheral models needed.
 *
 * Flow: init COM1, print 'A' (bridge alive), install an IVT[8] (IRQ0) handler in
 * the F000 segment, STI; HLT-loop. Each PS-injected vector-8 runs the handler,
 * which prints 'T' and IRETs; after 16 ticks it isa-debug-exits. Expected console:
 *   A TTTTTTTTTTTTTTTT   then a clean exit (no CPU_HUNG).
 *
 * Same flat 64 KiB -bios layout as psocfw (reset vector F000:FFF0). The tick
 * counter lives at low RAM 0:0x500 (ES=0) to dodge segment-offset truncation.
 */
    .equ COM1_THR, 0x03F8
    .equ COM1_DLL, 0x03F8
    .equ COM1_DLM, 0x03F9
    .equ COM1_LCR, 0x03FB
    .equ COM1_MCR, 0x03FC
    .equ TICKMAX,  16
    .equ TICKLOC,  0x0500          /* 0:0x500 — low-RAM tick counter */

    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ss
    movw    $0x7000, %sp
    movw    %ax, %es                    /* ES = 0 -> IVT + tick counter addressable */
    movw    $0xF000, %ax
    movw    %ax, %ds                    /* DS = F000 -> this image addressable */

#ifndef NO_IVT_WRITE
    /* install IRQ0 (vector 8) -> F000:irq0_off in the IVT (0:0x20 / 0:0x22).
     * Store through BX (not AX) so GAS emits the ModRM [disp16] form (89 /r) the
     * core decodes — the MOV moffs16,AX form (opcode A3) is NOT decoded. */
    movw    $irq0_off, %bx
    movw    %bx, %es:0x20               /* IVT[8].offset */
    movw    $0xF000, %bx
    movw    %bx, %es:0x22               /* IVT[8].segment */
#endif
    xorw    %bx, %bx
    movw    %bx, %es:TICKLOC            /* tick counter = 0 */

    /* init COM1 16550: DLAB=1, divisor=1 (115200), 8N1, DTR+RTS */
    movw    $COM1_LCR, %dx; movb $0x83, %al; outb %al, %dx
    movw    $COM1_DLL, %dx; movb $0x01, %al; outb %al, %dx
    movw    $COM1_DLM, %dx; movb $0x00, %al; outb %al, %dx
    movw    $COM1_LCR, %dx; movb $0x03, %al; outb %al, %dx
    movw    $COM1_MCR, %dx; movb $0x03, %al; outb %al, %dx

    /* 'A' — the IO bridge is alive (cosim_en) */
    movw    $COM1_THR, %dx
    movb    $'A', %al
    outb    %al, %dx

    sti                                 /* allow the PS-injected IRQ0 */
    nop                                 /* STI shadow: IF takes effect after this */
1:  jmp     1b                          /* pure spin (no HLT) — isolates delivery */

    /* ---- IRQ0 handler: print 'T', count, isa-debug-exit after TICKMAX ---- */
    .global irq0
irq0:
    pushw   %ax
    pushw   %dx
    pushw   %es
    xorw    %ax, %ax
    movw    %ax, %es
    movw    $COM1_THR, %dx
    movb    $'T', %al
    outb    %al, %dx                    /* 'T' — a PS-injected interrupt was delivered */
    incw    %es:TICKLOC
    cmpw    $TICKMAX, %es:TICKLOC
    jb      9f
    movb    $0x42, %al                  /* TICKMAX reached -> isa-debug-exit */
    movw    $0xF4, %dx
    outb    %al, %dx
9:  popw    %es
    popw    %dx
    popw    %ax
    iret

    /* ===================== 16-bit reset stub @ 0xFFF0 ==================== */
    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
