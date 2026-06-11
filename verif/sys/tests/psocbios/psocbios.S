/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium F3 — minimal BIOS firmware using INT services (psocbios.bin).
 *
 * Demonstrates the full BIOS-service mechanism now that real-mode IVT INT/IRET works:
 * it installs an INT 10h teletype handler (AH=0Eh -> write AL to the COM1 console) in
 * the IVT, then prints a banner by CALLING that service (INT 10h) for each character.
 * Every char round-trips through real-mode interrupt delivery (push FLAGS:CS:IP, IVT
 * vector to the handler in segment F000) + IRET. The per-record differential vs
 * qemu-system checks the whole app -> INT -> handler -> IRET flow. No new RTL.
 *
 * (qemu runs THIS firmware as the -bios, so qemu executes the same int10_handler --
 * the gate verifies our BIOS routine + the delivery, not a qemu-provided BIOS.)
 */
    .equ COM1_THR, 0x03F8

    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ss
    movw    $0x7000, %sp
    movw    %ax, %ds                    /* DS=0 -> install the IVT entry (segment 0) */

    /* install INT 0x10 -> IVT[0x10] @ 0:0x40 = { int10_handler, segment 0xF000 } */
    movw    $int10_off, 0x0040
    movw    $0xF000,     0x0042

    /* print the banner via the INT 10h teletype service */
    movw    $0xF000, %ax
    movw    %ax, %ds                    /* DS=F000 -> the banner string is addressable */
    movw    $banner_off, %si
1:  lodsb                               /* AL = next char */
    testb   %al, %al
    jz      2f
    movb    $0x0E, %ah                  /* INT 10h AH=0Eh: teletype output */
    int     $0x10                       /* -> int10_handler prints AL to COM1 */
    jmp     1b
2:
    /* isa-debug-exit: out 0xf4, al=0x42 -> status 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
3:  hlt
    jmp     3b

    /* ---- INT 10h handler (the BIOS video service; here routed to COM1) -------- */
    .global int10_handler
int10_handler:
    cmpb    $0x0E, %ah                  /* only the teletype function is modeled */
    jne     4f
    pushw   %dx
    movw    $COM1_THR, %dx
    outb    %al, %dx                    /* write the char to the COM1 console */
    popw    %dx
4:  iret

    .global banner
banner:
    .asciz  "Ventium BIOS: INT 10h teletype up\r\n"

    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
