/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium F2 — SoC boot FIRMWARE (psocfw.bin): boot + console output + clean exit.
 *
 * The smallest REAL firmware (vs the pboot test stubs): a reset-vector -bios image
 * that stays in 16-bit real mode, initialises the COM1 16550 UART (8N1, 115200), and
 * prints a banner string to it character-by-character, then isa-debug-exits. This is
 * the guest half of the F2 milestone the PS app (sw/ps/ven_soc_app) documents:
 * "boot + console output + clean exit". On the board the PS app's service_out routes
 * the COM1 THR bytes (0x3F8) to the Linux console; in cosim the differential vs
 * qemu-system-i386 checks the boot + every UART access per-record.
 *
 * The banner lives in the F000 segment (the -bios image), so DS is set to 0xF000 and
 * the string is read with the LODSB string engine (DS:SI) -- the core's supported
 * real-mode source addressing (register-indirect [si] direct is not decoded; the
 * string engine + [disp16] are). The COM1 THR (the PS-emulated UART / the RTL model)
 * always accepts a byte, so the bytes are written back-to-back without an LSR poll --
 * a real 16550 would poll THR-empty (LSR bit5); here it is always ready, which keeps
 * the run fully deterministic + per-record differentiable.
 */
    .equ COM1_THR, 0x03F8
    .equ COM1_DLL, 0x03F8
    .equ COM1_DLM, 0x03F9
    .equ COM1_LCR, 0x03FB
    .equ COM1_MCR, 0x03FC

    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ss
    movw    %ax, %es
    movw    $0x7000, %sp
    movw    $0xF000, %ax
    movw    %ax, %ds                    /* DS = F000 -> the banner (this segment) is addressable */

    /* init COM1 16550: DLAB=1, divisor=1 (115200), 8N1, DTR+RTS */
    movw    $COM1_LCR, %dx; movb $0x83, %al; outb %al, %dx   /* DLAB=1, 8N1 */
    movw    $COM1_DLL, %dx; movb $0x01, %al; outb %al, %dx   /* divisor low  = 1 */
    movw    $COM1_DLM, %dx; movb $0x00, %al; outb %al, %dx   /* divisor high = 0 */
    movw    $COM1_LCR, %dx; movb $0x03, %al; outb %al, %dx   /* DLAB=0, 8N1 */
    movw    $COM1_MCR, %dx; movb $0x03, %al; outb %al, %dx   /* DTR + RTS */

    /* print the banner: LODSB (DS:SI) until the NUL terminator */
    movw    $banner_off, %si              /* SI = banner offset within segment F000 */
1:  lodsb                               /* AL = DS:[SI], SI++ */
    testb   %al, %al
    jz      2f
    movw    $COM1_THR, %dx
    outb    %al, %dx                    /* write the char to COM1 THR */
    jmp     1b
2:
    /* isa-debug-exit: out 0xf4, al=0x42 -> status 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
3:  hlt
    jmp     3b

    .global banner
banner:
    .asciz  "Ventium SoC: Pentium (P54C) core alive on KV260\r\n"

    /* ===================== 16-bit reset stub @ 0xFFF0 ==================== */
    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
