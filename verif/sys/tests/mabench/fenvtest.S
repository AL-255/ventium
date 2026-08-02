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

    /* ---- REVIEW1_Aug2 H-12: ES (and therefore B) must actually be DERIVED -------
     * FSW.ES is the error summary: set when an exception flag is raised AND that
     * exception is UNMASKED. Nothing derived it, so ES was 0 in every one of the
     * 10165 fstat records the previous round measured -- which also made the B:=ES
     * mirror (bit 15) completely inert, since B is a copy of a bit that was never set.
     *
     * FNSTENV above has just re-masked everything (that is the M-01 behaviour this
     * test exists for), so clear the masks again, then raise a genuine INVALID
     * OPERATION with IM clear: 0.0 / 0.0. That must set IE (bit 0), and because IE is
     * unmasked it must also set ES (bit 7) and B (bit 15).
     *
     * Expected FSW: IE|ES|B = 0x0001 | 0x0080 | 0x8000 = 0x8081, plus whatever C0..C3
     * the operation leaves. The check masks to those three bits so it does not depend
     * on the condition codes. A core that does not derive ES reads 0x0001 here. */
    fldcw   0x0600                    /* CW = 0x0340 again, ALL MASKS CLEAR */
    fldz                              /* ST0 = 0.0 */
    fldz                              /* ST0 = 0.0, ST1 = 0.0 */
    fdivp   %st, %st(1)               /* 0.0 / 0.0 -> INVALID OPERATION, IE set */
    fnstsw  0x0606                    /* witness: IE|ES|B must all be set */

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
    movb $' ',%al; outb %al,%dx
    movb $'S',%al; outb %al,%dx
    movb $'W',%al; outb %al,%dx
    movb $'=',%al; outb %al,%dx
    /* REVIEW1_Aug2 H-12: report only IE|ES|B so the condition codes do not matter. */
    movw 0x0606, %ax
    andw $0x8081, %ax
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

    /* ==== REVIEW1_Aug2 M-04: the 14-byte (16-bit) FNSTENV / FLDENV ==============
     * This is .code16, so a *prefixless* FNSTENV selects the 14-BYTE form (the 28-byte
     * case above says 0x66 explicitly). The sequencer emitted the 28-byte image for
     * both: right-looking at +0, while 14 bytes of the guest's memory PAST the object
     * were destroyed. Three witnesses, each aimed at a different half of the defect:
     *
     *   E1 = [0x0724]   LAYOUT probe. At +4 the 14-byte form has TW; the 28-byte form
     *                   has SW. FNINIT leaves TW=0xffff and SW=0x0000, so this one
     *                   word says which layout was actually written. Reading +0 would
     *                   NOT discriminate -- CW is at +0 in both.
     *   E2 = [0x072e]   CORRUPTION witness: the first word past a 14-byte object,
     *                   poisoned 0xeeee. The 28-byte image reaches +27 and destroys it.
     *   E3              CW after a 14-byte FLDENV round trip: the load half has to read
     *                   back the same layout the store half wrote.
     */
    fninit                            /* CW=0x037f  TW=0xffff  SW=0x0000 */

    movw    $0x0720, %di              /* poison 0x0720..0x0737 (24 bytes) */
    movw    $12, %cx
    movw    $0xeeee, %ax
1:  movw    %ax, (%di)
    addw    $2, %di
    decw    %cx
    jnz     1b

    fnstenv 0x0720                    /* 14-byte form -- deliberately NO 0x66 */

    movw    0x0724, %ax; movw %ax, 0x0740      /* E1: layout probe */
    movw    0x072e, %ax; movw %ax, 0x0742      /* E2: corruption witness */

    movw    $0x0340, 0x0600
    fldcw   0x0600                    /* perturb CW away from the saved 0x037f */
    fldenv  0x0720                    /* 14-byte load must restore CW=0x037f */
    fnstcw  0x0744                    /* E3: round-trip witness */

    movw    $0x03F8,%dx
    movb    $'E',%al; outb %al,%dx
    movb    $'1',%al; outb %al,%dx
    movb    $'=',%al; outb %al,%dx
    movw    0x0740, %ax
    call    puthexw
    movw    $0x03F8,%dx; movb $' ',%al; outb %al,%dx
    movb    $'E',%al; outb %al,%dx
    movb    $'2',%al; outb %al,%dx
    movb    $'=',%al; outb %al,%dx
    movw    0x0742, %ax
    call    puthexw
    movw    $0x03F8,%dx; movb $' ',%al; outb %al,%dx
    movb    $'E',%al; outb %al,%dx
    movb    $'3',%al; outb %al,%dx
    movb    $'=',%al; outb %al,%dx
    movw    0x0744, %ax
    call    puthexw
    movw    $0x03F8,%dx
    movb    $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx

    /* ==== REVIEW1_Aug2 M-04, second half: the 94-byte FNSAVE / FRSTOR ===========
     * Same 640 bits of ST register data as the 108-byte form, delivered as 40 WORD
     * beats instead of 20 dword beats -- 47 beats in all, which is why the counter
     * needed a sixth bit. Witnesses:
     *   E4 = [0x0804]  layout probe again (TW at +4, not SW)
     *   E5 = [0x077e]  CORRUPTION witness: first word past a 94-byte object at
     *                  0x0800..0x085d. Poisoned eeee. (Placed BELOW the buffer as
     *                  well as above, so an overrun in either direction shows.)
     *   E6 = [0x085e]  the same, immediately past the 94-byte end.
     *   E7            ST0 after a 94-byte FNSAVE/FRSTOR round trip. FNSAVE reinits
     *                 the FPU, so a working FRSTOR is the ONLY way this comes back.
     */
    fninit
    fldpi                             /* ST0 = pi -- a value with a distinctive mantissa */

    movw    $0x077e, %di              /* poison 0x077e..0x0861 (0x72 bytes) */
    movw    $114, %cx                 /* 0x077e..0x0861 = 228 bytes = 114 words */
    movw    $0xeeee, %ax
1:  movw    %ax, (%di)
    addw    $2, %di
    decw    %cx
    jnz     1b

    fnsave  0x0800                    /* 94-byte form -- deliberately NO 0x66 */
    /* FNSAVE has now reinitialized the FPU: ST0 is empty and CW is back to 0x037f. */

    movw    0x0804, %ax; movw %ax, 0x0746      /* E4: layout probe */
    movw    0x077e, %ax; movw %ax, 0x0748      /* E5: underrun witness */
    movw    0x085e, %ax; movw %ax, 0x074a      /* E6: overrun witness */

    frstor  0x0800                    /* 94-byte load: must bring pi back into ST0 */
    fistpl  0x074c                     /* E7 = (int)ST0 -- pi truncates to 3 */

    movw    $0x03F8,%dx
    movb    $'E',%al; outb %al,%dx
    movb    $'4',%al; outb %al,%dx
    movb    $'=',%al; outb %al,%dx
    movw    0x0746, %ax
    call    puthexw
    movw    $0x03F8,%dx; movb $' ',%al; outb %al,%dx
    movb    $'E',%al; outb %al,%dx
    movb    $'5',%al; outb %al,%dx
    movb    $'=',%al; outb %al,%dx
    movw    0x0748, %ax
    call    puthexw
    movw    $0x03F8,%dx; movb $' ',%al; outb %al,%dx
    movb    $'E',%al; outb %al,%dx
    movb    $'6',%al; outb %al,%dx
    movb    $'=',%al; outb %al,%dx
    movw    0x074a, %ax
    call    puthexw
    movw    $0x03F8,%dx; movb $' ',%al; outb %al,%dx
    movb    $'E',%al; outb %al,%dx
    movb    $'7',%al; outb %al,%dx
    movb    $'=',%al; outb %al,%dx
    movw    0x074c, %ax
    call    puthexw
    movw    $0x03F8,%dx
    movb    $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx

    /* clean exit via isa-debug-exit (status = (0x42<<1)|1 = 133) */
    movb $0x42,%al; movw $0xF4,%dx; outb %al,%dx
9:  hlt; jmp 9b

/* AX = value to print as 4 hex digits on COM1. Clobbers AX/BX/CX/DX (the callers
 * above stash anything they still need in memory first, which is why the witnesses
 * are written to 0x0740.. before any printing starts). */
puthexw:
    movw    $4, %cx
1:  rolw    $4, %ax
    movb    %al, %bl
    andb    $0x0F, %bl
    cmpb    $10, %bl
    jb      2f
    addb    $87, %bl
    jmp     3f
2:  addb    $48, %bl
3:  pushw   %ax
    movb    %bl, %al
    movw    $0x03F8, %dx
    outb    %al, %dx
    popw    %ax
    decw    %cx
    jnz     1b
    ret

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
