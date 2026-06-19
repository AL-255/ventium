/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Ventium coverage: port I/O — IN/OUT (imm8 + DX) + the string forms INS/OUTS,
 * exercising core_io.svh S_IO / S_INS. Privileged in user mode; run under
 * ventium_top --system --cosim (the cosim io-bridge services the ports inertly).
 * COVERAGE-ONLY (no golden).
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    movw    $0x0080, %dx
    inb     %dx, %al            /* IN AL, DX   -> S_IO */
    inw     %dx, %ax            /* IN AX, DX */
    outb    %al, %dx            /* OUT DX, AL  -> S_IO */
    outw    %ax, %dx            /* OUT DX, AX */
    inb     $0x80, %al          /* IN AL, imm8 */
    outb    %al, $0x80          /* OUT imm8, AL */
    movw    $0x1000, %di
    movw    $0x0003, %cx
    xorw    %cx, %cx
    rep insb                    /* REP INSB cx=0 -> S_INS rep_active cx==0 */
    movw    $0x1000, %di
    movw    $0x0003, %cx
    rep insb                    /* REP INSB cx=3 -> S_INS */
    movw    $0x2000, %si
    movw    $0x0002, %cx
    rep outsb                   /* REP OUTSB */

    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx            /* isa-debug-exit */
1:  hlt
    jmp     1b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
