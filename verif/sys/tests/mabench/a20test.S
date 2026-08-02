/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * a20test — REVIEW2 M-03 regression test for the A20 gate.
 *
 * The A20 gate was ABSENT from the design: no masking anywhere in the core and no
 * top-level control, so accesses that must ALIAS at 1 MiB stayed distinct in memory
 * and in the caches. This is the classic HMA wrap, exercised the way real BIOS and
 * DOS code does it: a real-mode seg:off whose linear sum exceeds 1 MiB.
 *
 *   ES = 0xFFFF, offset 0x0510  ->  linear 0xFFFF0 + 0x0510 = 0x0010_0500
 *
 * With A20 ENABLED that is a distinct address from linear 0x0000_0500.
 * With A20 DISABLED bit 20 is forced low, so it becomes 0x0000_0500 -- the SAME
 * dword, and a write through the high alias is visible through the low one.
 *
 * The test carries its own CONTROL so a pass cannot be an accident:
 *   phase 1 (A20 on)  : the high write must NOT disturb the low location
 *   phase 2 (A20 off) : the high write MUST land on the low location
 * A build with no A20 support at all fails phase 2; a build that wrongly masks all
 * the time fails phase 1. Only correct gating passes both.
 *
 * Output: "A=1111 B=3333 D=3333" on the serial port, then isa-debug-exit.
 *   A: A20 ENABLED  -> the 1 MiB aliases stay DISTINCT
 *   B: A20 DISABLED via port 0x92 -> the high write WRAPS onto the low one
 *   D: A20 RE-ENABLED via the 8042 0xD1/0x60 sequence (REVIEW1_Aug2 H-10) -> the
 *      aliasing STOPS, so the low location keeps B's value instead of taking 0x4444
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli; cld
    xorw %ax,%ax; movw %ax,%ss; movw %ax,%ds; movw $0x7000,%sp
    /* 16550 init so the harness can read the result string */
    movw $0x03FB,%dx; movb $0x83,%al; outb %al,%dx
    movw $0x03F8,%dx; movb $0x01,%al; outb %al,%dx
    movw $0x03FB,%dx; movb $0x03,%al; outb %al,%dx
    movw $0x03FC,%dx; movb $0x03,%al; outb %al,%dx

    /* ES:0x0510 == linear 0x00100500 (1 MiB + 0x500) when A20 is ENABLED. */
    movw $0xFFFF,%ax; movw %ax,%es

    /* ---- phase 1: A20 ENABLED (reset state) -> the two must NOT alias ---- */
    movw $0x1111, %bx
    movw %bx, 0x0500                  /* [linear 0x000500] = 0x1111 */
    movw $0x2222, %bx
    movw %bx, %es:0x0510              /* [linear 0x100500] = 0x2222 (distinct) */
    movw 0x0500, %si                  /* SI = low location; want STILL 0x1111 */

    /* ---- disable A20 via port 0x92 (System Control Port A), bit 1 = 0 ----
     * bit 0 is FAST RESET and must stay 0. */
    xorb %al,%al
    movw $0x0092,%dx
    outb %al,%dx

    /* ---- phase 2: A20 DISABLED -> the high write must WRAP onto the low one ---- */
    movw $0x3333, %bx
    movw %bx, %es:0x0510              /* now linear 0x000500 (bit 20 forced low) */
    movw 0x0500, %di                  /* DI = low location; want 0x3333 */

    /* ---- phase 3: RE-ENABLE A20 through the CLASSIC 8042 SEQUENCE -------------
     * REVIEW1_Aug2 H-10. Port 0x92 above is the "fast" A20. The route real BIOS and
     * DOS actually use goes through the keyboard controller:
     *     OUT 0x64, 0xD1     command: write the 8042 output port
     *     OUT 0x60, <data>   bit 1 of <data> is A20
     * Nothing connected that to the gate, so this sequence changed NOTHING. It is
     * used here to RE-ENABLE A20 (bit 1 = 1) after phase 2 disabled it, so the check
     * is that the aliasing STOPS -- which only a working KBC path can produce, and
     * which the port-0x92 phases cannot fake.
     * (No status-port polling: this test's 8042 is the co-sim model and the writes
     *  complete when the OUT retires.) */
    movb $0xD1,%al
    movw $0x0064,%dx
    outb %al,%dx
    movb $0x02,%al                    /* bit 1 = 1 -> A20 ENABLED */
    movw $0x0060,%dx
    outb %al,%dx

    movw $0x4444, %bx
    movw %bx, %es:0x0510              /* linear 0x100500 again IF A20 is back on */
    movw 0x0500, %bx                  /* low location: must STILL be 0x3333 */
    movw %bx, 0x0600                  /* stash it -- puthex16 clobbers BX and CX, so
                                       * no register survives to the print below */

    /* ---- diagnostic: read 0x0510 through DS (no override). If the ES override
     * were being IGNORED, the phase-1/2 writes would have landed here at linear
     * 0x0510 instead of 0x100500, which would explain A/B without A20 being
     * involved at all. C tells the two apart. ---- */
    movw 0x0510, %bp

    /* ---- print "A=" SI " B=" DI " C=" BP ---- */
    movw $0x03F8,%dx
    movb $'A',%al; outb %al,%dx; movb $'=',%al; outb %al,%dx
    movw %si,%ax; call puthex16
    movb $' ',%al; outb %al,%dx
    movb $'B',%al; outb %al,%dx; movb $'=',%al; outb %al,%dx
    movw %di,%ax; call puthex16
    movb $' ',%al; outb %al,%dx
    movb $'C',%al; outb %al,%dx; movb $'=',%al; outb %al,%dx
    movw %bp,%ax; call puthex16
    movb $' ',%al; outb %al,%dx
    movb $'D',%al; outb %al,%dx; movb $'=',%al; outb %al,%dx
    movw 0x0600,%ax; call puthex16  /* REVIEW1_Aug2 H-10: the 8042 A20 re-enable */
    movb $13,%al; outb %al,%dx; movb $10,%al; outb %al,%dx

    /* clean exit via isa-debug-exit (status = (0x42<<1)|1 = 133) */
    movb $0x42,%al; movw $0xF4,%dx; outb %al,%dx
9:  hlt; jmp 9b

/* puthex16: print AX as 4 hex digits on the port already in DX (0x3F8). */
puthex16:
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
    ret

    .section .reset,"ax"
    .global _reset
_reset:
    .byte 0xEA; .word _start16_off; .word 0xF000
