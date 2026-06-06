/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M2S.4 — linker script for the bare-metal CROSS-PRIVILEGE image.
 *
 * Identical layout strategy to the M2S.0 pmode / M2S.1 pseg / M2S.2 ppage /
 * M2S.3 pintr/pfault images: a flat 64 KiB BIOS image.  qemu-system-i386 -bios
 * maps it so the last byte is at physical 0x000FFFFF; the reset vector is
 * CS:EIP=F000:FFF0 (linear 0x000FFFF0).  So:
 *   - the image base linear address is 0x000F0000 (= 0x100000 - 0x10000)
 *   - .reset (the 16-bit reset stub) must land at linear 0x000FFFF0, image
 *     offset 0xFFF0
 *   - .text16 (the 16-bit entry) + the 32-bit body + the CPL3 task + handlers
 *     sit early in the image, all within the 0xF000 real-mode segment so
 *     `ljmp $0xF000,$off` reaches them, and all in flat code segments (base 0)
 *     so the IDT gate offsets ($xcpl_handler etc.) + the CPL3 user_entry are
 *     full 0x000Fxxxx linear addresses.
 *
 * NO paging in pcpl, so the handler/gate-target/user-task linear addresses are
 * physical; the GDT (0x500) / IDT (0x1000) / markers (0x2000) / TSS (0x3000) /
 * the three stacks (0x80000 / 0x88000 / 0x90000) all live in low RAM, distinct
 * from the 0x000Fxxxx image window.
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;   /* linear base of a 64 KiB -bios image */

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : {
        *(.text16)
    }

    /* segment-relative offset of the real-mode entry inside segment 0xF000,
     * computed at link time as an ABSOLUTE constant so the reset stub's hand
     * encoded far jump can use a 16-bit immediate that already fits. */
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);

    .text32 : {
        . = ALIGN(16);
        *(.text32)
        *(.text)
        *(.rodata*)
        *(.data*)
    }

    /* The reset stub goes at the very end: image offset 0xFFF0 == linear FFFF0. */
    . = IMAGE_BASE + 0xFFF0;
    .reset : {
        *(.reset)
    }

    /* discard everything else */
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
