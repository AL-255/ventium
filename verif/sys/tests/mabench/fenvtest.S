/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * fenvtest — REVIEW2 M-01 self-check: FNSTENV must MASK ALL x87 EXCEPTIONS.
 *
 * SDM Vol.2 (FSTENV/FNSTENV): "After saving the FPU environment, the FPU exception
 * masks are set" -- i.e. FCW[5:0] <- 6'b111111. Ventium did not do this.
 *
 * WHY THIS IS A SELF-CHECK AND NOT A DIFFERENTIAL TEST.
 * The differential gate cannot grade this behaviour, for two independent reasons:
 *
 *  1. The DEFAULT control word 0x037F ALREADY has bits[5:0] = 0x3F, so on every
 *     existing x87 test `fctrl | 0x3F` is a NO-OP. `make verify` passing 98/98 with
 *     the fix in place says nothing about it -- the behaviour is never reached.
 *     This test therefore FIRST CLEARS the mask bits (CW = 0x0340) so the store has
 *     something to change.
 *
 *  2. QEMU DOES NOT IMPLEMENT IT. do_fstenv() in target/i386/tcg/fpu_helper.c stores
 *     the environment and returns; there is no `fpuc |= 0x3f` anywhere in the tree
 *     (verified by grep). So the ORACLE IS WRONG HERE, and a differential test would
 *     fail precisely when Ventium is architecturally CORRECT.
 *
 * The 0x66 operand-size prefix selects the 28-byte environment, which is the form
 * Ventium implements; the 14-byte 16-bit form is the remaining half of M-01.
 *
 * Output: "CW=03ff" on the serial port (all six mask bits set again), then exit.
 *   before FNSTENV : CW = 0x0340  (PC=11, reserved bit 6 = 1, ALL MASKS CLEAR)
 *   after  FNSTENV : CW = 0x037F  (the same word with bits[5:0] set)
 * A core that does not implement the masking prints CW=0340 and the gate fails.
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli; cld
    xorw %ax,%ax; movw %ax,%ss; movw %ax,%ds; movw %ax,%es; movw $0x7000,%sp
    /* 16550 init so the harness can read the result */
    movw $0x03FB,%dx; movb $0x83,%al; outb %al,%dx
    movw $0x03F8,%dx; movb $0x01,%al; outb %al,%dx
    movw $0x03FB,%dx; movb $0x03,%al; outb %al,%dx
    movw $0x03FC,%dx; movb $0x03,%al; outb %al,%dx

    /* Scratch lives at fixed LOW addresses reached through DS=0, not via labels:
     * this image is linked at 0x000F0000 and 16-bit relocations against .text16
     * do not fit (R_386_16 truncation), which is why the other mabench tests use
     * absolute offsets too.
     *   [0x0600] = the control word to load   [0x0602] = CW witness before
     *   [0x0604] = CW witness after           [0x0700] = the 28-byte env buffer */
    movw    $0x0340, 0x0600           /* PC=11, RC=00, bit6=1, ALL MASKS CLEAR */

    fninit                            /* CW = 0x037F, all masks SET */
    fldcw   0x0600                    /* CW = 0x0340, all masks CLEAR */
    fnstcw  0x0602                    /* witness: should read 0x0340 */

    /* 28-byte (32-bit) FNSTENV via the 0x66 operand-size prefix (FNSTENV = D9 /6). */
    .byte 0x66
    fnstenv 0x0700

    fnstcw  0x0604                    /* THE CHECK: must now read 0x037F */

    /* ---- print "CW=" hex(cw_after) ---- */
    movw $0x03F8,%dx
    movb $'C',%al; outb %al,%dx
    movb $'W',%al; outb %al,%dx
    movb $'=',%al; outb %al,%dx
    movw 0x0604, %ax
    movw $4, %cx
1:  rolw $4, %ax
    movb %al, %bl
    andb $0x0F, %bl
    cmpb $10, %bl
    jb 2f
    addb $87, %bl
    jmp 3f
2:  addb $48, %bl
3:  pushw %ax
    movb %bl, %al
    movw $0x03F8,%dx
    outb %al,%dx
    popw %ax
    decw %cx
    jnz 1b
    movb $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx

    /* clean exit via isa-debug-exit (status = (0x42<<1)|1 = 133) */
    movb $0x42,%al; movw $0xF4,%dx; outb %al,%dx
9:  hlt; jmp 9b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
