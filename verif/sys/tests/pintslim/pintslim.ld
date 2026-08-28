/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Linker script for the pintslim bare-metal image. A flat 64 KiB BIOS
 * image, mapped so the last byte is at physical 0x000FFFFF and the reset
 * vector is CS:EIP=F000:FFF0 (linear 0x000FFFF0). All test state lives in
 * low RAM, distinct from the 0x000Fxxxx image window. All code segments are
 * based at 0xF0000, so every code symbol is used as (label - IMAGE_BASE).
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

    _pm32_off = ABSOLUTE(pm_entry - IMAGE_BASE);
    _r3_off   = ABSOLUTE(r3_entry - IMAGE_BASE);
    _h16_off  = ABSOLUTE(h16 - IMAGE_BASE);
    _h32_off  = ABSOLUTE(h32 - IMAGE_BASE);
    _hss_off  = ABSOLUTE(h_ss - IMAGE_BASE);
    _hss0_off = ABSOLUTE(h_ss0 - IMAGE_BASE);
    _i40_off  = ABSOLUTE(i40 - IMAGE_BASE);
    _i41_off  = ABSOLUTE(i41 - IMAGE_BASE);
    _i42_off  = ABSOLUTE(i42 - IMAGE_BASE);
    _i43_off  = ABSOLUTE(i43 - IMAGE_BASE);
    _r16r0_off = ABSOLUTE(r16r0 - IMAGE_BASE);
    _r16r1_off = ABSOLUTE(r16r1 - IMAGE_BASE);
    _r16r2_off = ABSOLUTE(r16r2 - IMAGE_BASE);
    _r16r3_off = ABSOLUTE(r16r3 - IMAGE_BASE);
    _rdone0_off = ABSOLUTE(rdone0 - IMAGE_BASE);
    _rdone1_off = ABSOLUTE(rdone1 - IMAGE_BASE);
    _rdone2_off = ABSOLUTE(rdone2 - IMAGE_BASE);
    _rdone3_off = ABSOLUTE(rdone3 - IMAGE_BASE);

    /* The reset stub goes at the very end: image offset 0xFFF0 == linear FFFF0. */
    . = IMAGE_BASE + 0xFFF0;
    .reset : {
        *(.reset)
    }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
