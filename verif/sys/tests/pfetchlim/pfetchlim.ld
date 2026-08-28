/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* REVIEW1_Aug3 R2-H07 — linker script for the decoded-extent fetch-limit image.
 *
 * Same layout strategy as pseglim/pcslim: a flat 64 KiB BIOS image whose last
 * byte sits at physical 0x000FFFFF; the reset vector is F000:FFF0 (linear
 * 0x000FFFF0), so .reset lands at image offset 0xFFF0 and everything else sits
 * early, within the 0xF000 real-mode segment. The five limited code segments
 * get their bases from the case*_stub labels at runtime (see pfetchlim.S).
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;   /* linear base of a 64 KiB -bios image */

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : {
        *(.text16)
    }

    /* segment-relative offset of the real-mode entry inside segment 0xF000 */
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
