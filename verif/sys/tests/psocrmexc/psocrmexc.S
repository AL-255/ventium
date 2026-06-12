/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium F3 — real-mode EXCEPTION (#DE) IVT delivery firmware (psocrmexc.bin).
 *
 * Directed gate for the real-mode HARDWARE-EXCEPTION delivery path the core gains
 * with the start_fault(real_mode ? S_RMINT_RD : S_INT_GATE) fix: a pure real-mode
 * (PE=0) fault must vector through the 4-byte IVT, NOT the protected-mode 8-byte
 * gate. Unlike a maskable IRQ (nondeterministic boundary, needs the LAPIC which is
 * unreachable in real mode), a #DE is SYNCHRONOUS — the gdbstub single-step (NOIRQ|
 * NOTIMER masks only INTR/timer, never exceptions) delivers it deterministically, so
 * this is a full PER-RECORD differential vs qemu-system-i386, exactly like psocrmint.
 *
 * Flow: install IVT[0] (#DE) @ 0:0 = {offset=handler, segment=0xF000}; set a memory
 * divisor word to 0; DIVW by it -> #DE -> the core delivers through the IVT (pushes
 * FLAGS:CS:IP of the FAULTING div, loads CS:IP from IVT[0], clears IF/TF). The handler
 * (CS=0xF000) sets a marker, FIXES the divisor to a nonzero value, and IRETs. The fault
 * pushed the faulting IP (restart semantics), so the div RE-EXECUTES — now succeeding —
 * and control falls through to the post-marker + isa-debug-exit. cr0 stays real-mode.
 * The per-record diff checks the #DE frame push, the CS:IP vector load, the handler run,
 * the IRET restore, and the re-executed div, all vs qemu-system.
 */
    .equ DIVISOR, 0x0600                 /* a free low-RAM word used as the divisor */

    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds                     /* DS=0 -> the IVT (segment 0) + DIVISOR addressable */
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    /* install IVT[0] (#DE) @ 0:0x0000 = { offset=handler, segment=0xF000 } */
    movw    $handler_off, 0x0000         /* IVT[0].offset */
    movw    $0xF000,       0x0002        /* IVT[0].segment */

    /* set up the divide-by-zero: dividend DX:AX = 0x0000:0x0004, divisor [DIVISOR]=0 */
    movw    $0, DIVISOR                  /* divisor = 0 -> the DIVW will #DE */
    xorw    %dx, %dx
    movw    $0x0004, %ax
    movw    $0x1111, %bx                 /* pre-fault marker */

    divw    DIVISOR                      /* #DE (div by 0) -> real-mode IVT[0] delivery */

    movw    $0x3333, %cx                 /* post-resume marker: the re-executed div succeeded
                                          * (AX = 0x0004 / 2 = 0x0002) and control fell through */

    /* isa-debug-exit: out 0xf4, al=0x42 -> qemu status 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b

    /* the #DE handler (runs at CS=0xF000). Fixes the divisor so the restarted div
     * succeeds, then IRETs back to the faulting div (fault = restart semantics). */
    .global handler
handler:
    movw    $0x2222, %bx                 /* observable: the #DE handler ran */
    movw    $2, DIVISOR                  /* fix the divisor (DS=0 still) -> restart succeeds */
    iret                                 /* pop IP:CS:FLAGS -> back to the faulting DIVW */

    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
