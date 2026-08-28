/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium REVIEW_Aug4 A4-H03 — linker script for the bare-metal 16-bit-PM
 * interrupt-frame image. Same flat 64 KiB -bios layout as pintr16.ld: qemu
 * maps the image so the last byte is at physical 0x000FFFFF, the reset vector
 * is CS:EIP=F000:FFF0. ALL code segments (0x08/0x18/0x20) are BASED at
 * 0xF0000 so the per-segment offsets defined below are 16-bit clean — the
 * 16-bit gates store word offsets and the 16-bit frames push word IPs.
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

    /* Segment-relative offsets (linear - 0xF0000 == the code-segment base):
     * the mainline/ring-3 entries, the five 16-bit-gate handlers, and the two
     * 32-bit-gate control handlers. */
    _pm32_off = ABSOLUTE(pm_entry - IMAGE_BASE);
    _r3_off   = ABSOLUTE(r3_entry - IMAGE_BASE);
    _hc1_off  = ABSOLUTE(h16_c1 - IMAGE_BASE);
    _hc2_off  = ABSOLUTE(h16_c2 - IMAGE_BASE);
    _hc3_off  = ABSOLUTE(h16_c3 - IMAGE_BASE);
    _hc4_off  = ABSOLUTE(h16_c4 - IMAGE_BASE);
    _hc5_off  = ABSOLUTE(h16_c5 - IMAGE_BASE);
    _hc7_off  = ABSOLUTE(h_c7 - IMAGE_BASE);
    _hc7x_off = ABSOLUTE(h_c7x - IMAGE_BASE);

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
