/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium F3 — real-mode MOV Sreg,[mem] / MOV [mem],Sreg (incl. a32) firmware.
 *
 * Directed differential for the F3 segment memory-form moves the SeaBIOS call32
 * trampoline uses (saving/restoring es/ds/ss into a struct, with a 0x67 address-size
 * prefix). Exercises BOTH directions and BOTH address sizes vs qemu-system, fully
 * synchronous/deterministic -> a clean per-record gate:
 *   - MOV [mem16],Sreg  (8C, 16-bit addr)
 *   - MOV [eax],Sreg     (8C, a32  addr  -- the SeaBIOS form, 0x67 prefix)
 *   - MOV Sreg,[mem16]   (8E, 16-bit addr)
 *   - MOV Sreg,[eax]     (8E, a32  addr  -- the SeaBIOS form)
 * Each result selector + the stored memory word is surfaced into a GPR so compare.py
 * sees them per-record. DS stays 0 so the disp16/[eax] addresses are linear; cr0 stays
 * real-mode (PE=0).
 */
    .equ SCRATCH, 0x0600                 /* a free low-RAM scratch word */

    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds                     /* DS=0 -> SCRATCH is linear */
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    /* --- 8C, 16-bit addr: store ES selector to [SCRATCH] --- */
    movw    $0x1234, %ax
    movw    %ax, %es                     /* ES = 0x1234 */
    movw    %es, SCRATCH                 /* 8C /r disp16 -> [0x600] = 0x1234 */
    movw    SCRATCH, %bx                 /* bx = 0x1234 (store readback) */

    /* --- 8C, a32 addr: store SS selector to [eax] (the SeaBIOS form, 0x67) --- */
    movl    $SCRATCH, %eax
    movw    %ss, (%eax)                  /* 8C /r a32 -> [0x600] = SS = 0x0000 */
    movw    SCRATCH, %cx                 /* cx = 0x0000 */

    /* --- 8E, 16-bit addr: load FS selector from [SCRATCH] --- */
    movw    $0x9ABC, SCRATCH             /* [0x600] = 0x9ABC */
    movw    SCRATCH, %fs                 /* 8E /r disp16 -> FS = 0x9ABC */
    movw    %fs, %dx                     /* dx = 0x9ABC */

    /* --- 8E, a32 addr: load GS selector from [eax] (the SeaBIOS form, 0x67) --- */
    movw    $0xDEF0, SCRATCH             /* [0x600] = 0xDEF0 */
    movl    $SCRATCH, %eax
    movw    (%eax), %gs                  /* 8E /r a32 -> GS = 0xDEF0 */
    movw    %gs, %si                     /* si = 0xDEF0 */

    /* --- one-byte PUSH/POP segment register (06/0E/16/1E, 07/17/1F) --- */
    /* (done last: POP DS clobbers DS, but no [SCRATCH] access follows.) */
    movw    $0x4321, %ax
    movw    %ax, %es                     /* ES = 0x4321 */
    pushw   %es                          /* 0x06 PUSH ES -> stack = 0x4321 */
    popw    %ds                          /* 0x1F POP DS  -> DS = 0x4321 */
    movw    %ds, %bp                     /* bp = 0x4321 (PUSH ES + POP DS) */

    pushw   %cs                          /* 0x0E PUSH CS -> stack = 0xF000 */
    popw    %es                          /* 0x07 POP ES  -> ES = 0xF000 */
    movw    %es, %di                     /* di = 0xF000 (PUSH CS + POP ES) */

    /* isa-debug-exit: out 0xf4, al=0x42 -> qemu status 133 */
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
