/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium REVIEW_Aug4 A4-C02 — linker script for the bare-metal far-transfer
 * target-offset-vs-limit image. Same layout strategy as pjmpgate: a flat
 * 64 KiB BIOS image, qemu maps it so the last byte is at physical 0x000FFFFF,
 * the reset vector is CS:EIP=F000:FFF0 (linear 0x000FFFF0). No paging. The
 * .marker section pins the one-byte boundary `lret` at image offset 0x8000
 * (linear 0x000F8000) so that the limited target segment (base 0xF0000,
 * limit 0x8000) maps offset == limit exactly onto it.
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;   /* linear base of a 64 KiB -bios image */

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : {
        *(.text16)
    }

    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);

    .text32 : {
        . = ALIGN(16);
        *(.text32)
        *(.text)
        *(.rodata*)
        *(.data*)
    }

    /* The boundary marker: image offset 0x8000 == linear 0xF8000 ==
     * limited-target offset == limit (cases 2 and 3 land here). */
    . = IMAGE_BASE + 0x8000;
    .marker : {
        *(.marker)
    }

    /* The reset stub goes at the very end: image offset 0xFFF0 == linear FFFF0. */
    . = IMAGE_BASE + 0xFFF0;
    .reset : {
        *(.reset)
    }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
