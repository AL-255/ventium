/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M9.5 — real-mode LES/LDS/LSS/LFS/LGS firmware (psoclseg.bin).
 *
 * Builds a far pointer {off=0x1234, sel=0x5678} in RAM at 0:0x0600, then loads it
 * with each of the five segment-load instructions: the GPR gets the offset, the
 * named segment register gets the selector (base = sel<<4). DS and SS are loaded
 * LAST (after the [0x600] reads + the stack-using ops) so the changed segment never
 * breaks a later access. Per-record differential vs qemu-system checks each GPR +
 * segment selector. cr0 stays the reset 0x60000010 (pure 16-bit real mode).
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

    /* far pointer at 0:0x0600 = { off=0x1234, sel=0x5678 } */
    movw    $0x1234, 0x0600
    movw    $0x5678, 0x0602

    les     0x0600, %bx          /* bx=0x1234, ES=0x5678 (addressing DS unchanged) */
    lfs     0x0600, %si          /* si=0x1234, FS=0x5678 */
    lgs     0x0600, %di          /* di=0x1234, GS=0x5678 */
    lss     0x0600, %bp          /* bp=0x1234, SS=0x5678 (stack moves; no more stack ops) */
    lds     0x0600, %cx          /* cx=0x1234, DS=0x5678 -- LAST (DS is the addr seg) */

    /* isa-debug-exit: out 0xf4, al=0x42 -> status 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
