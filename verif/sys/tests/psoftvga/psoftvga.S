/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium task #99 — bare-metal soft-VGA INT 10h unit test.
 *
 * Exercises the PS-side soft-VGA INT 10h handler (tb_main.cpp, VEN_SOFTVGA +
 * VEN_SOFTVGA_FORCE) the SAME way DOS Quake's mode-13h init does, but without a
 * full FreeDOS/CWSDPMI boot (which is blocked by the disk-detection issue):
 *   1. INT 10h AX=0013  -> set mode 13h (320x200x256). Soft-VGA writes BDA
 *      video mode 0x449=0x13, cols 0x44a=40.
 *   2. INT 10h AX=1012  -> set DAC palette block (ES:DX table, BX=0, CX=4): a
 *      few RGB entries so the rendered frame has color (routed into g_vga DAC).
 *   3. fill mode-13h framebuffer 0xA0000 with a test pattern (so the tb's VGA13
 *      dump captures a nonzero frame == "a frame rendered").
 *   4. INT 10h AX=0F00  -> get mode; verify AL==0x13 (proves the soft-VGA set it).
 *   5. report PASS/FAIL via the isa-debug-exit port 0xf4 (AL=0 => exit code 1).
 *
 * Runs entirely in real mode; the TB installs the C000:0 INT-10h trap stub +
 * IVT[0x10] at boot (VEN_SOFTVGA_FORCE), so `int $0x10` reaches the soft VGA.
 *
 * Image: a flat 64 KiB -bios image (reset stub at offset 0xFFF0 jumps to start).
 * Run:  VEN_SOFTVGA=1 VEN_SOFTVGA_FORCE=1 tb_ventium --image psoftvga.bin --dos
 */

    .code16
    .section .text16,"ax"
    .globl _start16
_start16:
    cli
    cld
    /* real-mode segments: DS=ES=SS=0, SP just under the BDA scratch top */
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    /* ---- 1) set mode 13h ---- */
    movw    $0x0013, %ax
    int     $0x10

    /* ---- 2) set DAC palette block: ES:DX -> RGB table, BX=start=0, CX=count=4 */
    movw    %cs, %ax            /* the palette table lives in CS (this image) */
    movw    %ax, %es
    movw    $_paltab_off, %dx   /* DX = segment-relative offset of paltab in CS */
    xorw    %bx, %bx            /* start index 0 */
    movw    $4, %cx             /* 4 entries */
    movw    $0x1012, %ax
    int     $0x10
    /* restore ES=0 for the framebuffer fill below */
    xorw    %ax, %ax
    movw    %ax, %es

    /* ---- 3) fill the mode-13h framebuffer 0xA0000 with a pattern ---- */
    /* ES=0xA000, DI=0 ; write 64000 bytes = a left-to-right color ramp by row */
    movw    $0xA000, %ax
    movw    %ax, %es
    xorw    %di, %di
    movw    $200, %bp           /* rows */
.row:
    movw    $320, %cx           /* cols */
    xorb    %al, %al
.col:
    stosb                       /* ES:[DI]=AL ; DI++ */
    incb    %al
    loop    .col
    decw    %bp
    jnz     .row

    /* ---- 4) get mode; AL should be 0x13 ---- */
    movw    $0x0F00, %ax
    int     $0x10
    cmpb    $0x13, %al
    jne     .fail

    /* PASS: isa-debug-exit AL=0 -> exit status 1 */
    xorb    %al, %al
    outb    %al, $0xf4
.hlt:
    hlt
    jmp     .hlt

.fail:
    movb    $0xFE, %al          /* nonzero AL -> distinct exit status */
    outb    %al, $0xf4
    jmp     .hlt

    /* DAC palette table: 4 RGB triples (6-bit VGA DAC values, 0..63). Kept in
     * .text16 so its CS-relative offset (_paltab_off) is a 16-bit immediate. */
    .align 4
    .globl paltab
paltab:
    .byte 0x00, 0x00, 0x00      /* 0: black */
    .byte 0x3F, 0x00, 0x00      /* 1: red   */
    .byte 0x00, 0x3F, 0x00      /* 2: green */
    .byte 0x00, 0x00, 0x3F      /* 3: blue  */

    /* ---- reset stub at image offset 0xFFF0 (linear 0xFFFF0) ---- */
    .section .reset,"ax"
    .globl _reset
_reset:
    /* far jump to F000:_start16_off (16-bit real-mode), reload CS=0xF000 */
    ljmp    $0xF000, $_start16_off
