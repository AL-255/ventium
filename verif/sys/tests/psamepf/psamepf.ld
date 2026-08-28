/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium REVIEW_Aug4 A4-H06 — linker script for the bare-metal same-
 * privilege partial-frame image. Flat 64 KiB -bios layout (pjmpgate/pintr16
 * convention); ALL code segments are BASED at 0xF0000 so the per-segment
 * offsets below are 16-bit clean (the 16-bit #PF gate stores a word offset
 * and its frame pushes word IPs). */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;   /* linear base of a 64 KiB -bios image */

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : {
        *(.text16)
    }

    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);

    _pm32_off = ABSOLUTE(pm_entry - IMAGE_BASE);
    _hgp_off  = ABSOLUTE(gpgp_handler - IMAGE_BASE);
    _hpf_off  = ABSOLUTE(pf16_handler - IMAGE_BASE);
    _fixa_off = ABSOLUTE(fixup_a - IMAGE_BASE);
    _fixb_off = ABSOLUTE(fixup_b - IMAGE_BASE);

    .text32 : {
        . = ALIGN(16);
        *(.text32)
        *(.text16pm)
        *(.text)
        *(.rodata*)
        *(.data*)
    }

    /* The reset stub goes at the very end: image offset 0xFFF0 == linear FFFF0. */
    . = IMAGE_BASE + 0xFFF0;
    .reset : {
        *(.reset)
    }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
