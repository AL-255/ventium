/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M9.5 — real-mode far CALL (0x9A) + RETF (0xCB) firmware (psocfarcall.bin).
 *
 * The smallest exerciser of the newly-implemented real-mode far CALL / RETF. A
 * reset-vector firmware stays in 16-bit real mode, sets up the stack, far-CALLs a
 * routine in the same segment (F000), the routine does an observable write and
 * RETFs back, then the firmware isa-debug-exits. Every step is synchronous and
 * deterministic, so the standard gen_trace.py --system single-step golden is a
 * valid per-record oracle. The per-record compare checks CS/EIP/ESP and the pushed
 * stack at each step, so the push (CS:IP) and pop are diffed directly vs qemu.
 *
 * cr0 stays the reset 0x60000010 (pure real mode, no PM, no paging). The far CALL /
 * RETF / reset-far-jmp are emitted as explicit bytes (like pboot_rm's far jmp) so the
 * selector:offset operands are pinned; far_target_off is a linker symbol (the routine
 * offset within segment F000, = far_target - IMAGE_BASE).
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

    /* far CALL F000:far_target  (9A off16 0xF000): push CS(=0xF000) + return IP,
     * load CS=0xF000 / IP=far_target_off, jump into the routine. */
    .byte   0x9A
    .word   far_target_off
    .word   0xF000
ret_site:
    /* control returns HERE after the routine's RETF (the pushed return IP) */
    movw    $0x1111, %bx                /* observable post-return marker */

    /* isa-debug-exit: out 0xf4, al=0x42 -> process status (0x42<<1)|1 = 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b

    /* ---- the far-called routine (same segment F000) -------------------- */
    .global far_target
far_target:
    movw    $0x2222, %cx                /* observable inside the called routine */
    .byte   0xCB                        /* RETF: pop IP, pop CS -> return to ret_site */

    /* ===================== 16-bit reset stub @ 0xFFF0 ==================== */
    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA                        /* far jmp 0xF000:_start16_off */
    .word   _start16_off
    .word   0xF000
